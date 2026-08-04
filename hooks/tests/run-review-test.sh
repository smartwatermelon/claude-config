#!/usr/bin/env bash
# Tests for run-review.sh
# Run from any directory: bash ~/.claude/hooks/tests/run-review-test.sh
#
# Tests cover:
#   1. set -e propagation: transient Claude CLI failure must produce log output beyond bare exit_code
#   2. Chunked review log: reviewer output must appear in REVIEW_LOG when chunked path runs
#   3. Chunked review with 0/N files reviewed is fail-closed (issue #200); 3b: partial skip still passes
#   4. Stderr hint: chunked review failure (blocking verdict) must emit workaround hint
#   5. review.timeout git config is honoured
#   6. make_mock_claude must handle double-quotes in output without script syntax errors
#   7. REVIEW_LOG env var must override the hardcoded production log path in run-review.sh
#   8. Empty reviewer output (exit 0, no stdout) must not block the commit
#   9. Chunked-mode timeout verdicts are skips, not warnings; all-timeout batch is fail-closed (#200)
#   10. sync/* branches skip review regardless of diff size
#   11. "VERDICT: Revise" is treated as a synonym for FAIL
#   12/13. adversarial-reviewer only blocks on SEVERITY: BLOCKING, matching code-reviewer (issue #199)
#   14. Empty/template-only commit message does not abort the script under pipefail (issue #148)
#   15. Codebase mode: stderr noise must not corrupt VERDICT parsing (issue #89)
#   16. EXIT trap cleanup includes DIFF_TMPFILE (issue #90) — static guard
#   17. Permission-only diff is still skipped after the SIGPIPE-safe rewrite (issues #166, #171)
#   18. "VERDICT: Revise" is treated as blocking FAIL in chunked mode (issue #173)
#   19. "VERDICT: Revise" is treated as blocking FAIL in full-diff mode (issue #173)
#   20. "VERDICT: Revise" is treated as blocking FAIL in codebase mode (issue #173); also
#       covers issue #159 (model logging in full-diff/codebase modes)
#   21. review.model git config overrides the default model passed to the CLI (issue #160)
#   22. CODE_REVIEWER_AGENT default resolves to the installed agent ID (issue #209)
#   23. review.adversarialModel overrides adversarial-reviewer's model independently
#       of review.model / REVIEW_MODE (issue #235)

set -euo pipefail

# Resolve script directory without cd to avoid CDPATH side effects.
# When CDPATH is set, 'cd relative/dir' prints the resolved path to stdout,
# polluting $(cd dir && pwd) with a doubled path. Use parameter expansion
# on an absolute form of BASH_SOURCE[0] to avoid any external commands.
_src="${BASH_SOURCE[0]}"
[[ "${_src}" == /* ]] || _src="${PWD}/${_src}"
SCRIPT_DIR="${_src%/*}"
unset _src
SUBJECT="${SCRIPT_DIR}/../run-review.sh"
# Each test sets its own REVIEW_LOG to a temp path and passes it as an env var
# to run-review.sh, preventing test runs from clobbering the production log at
# ~/.claude/last-review-result.log (Warning 2 fix: run-review.sh now honours
# REVIEW_LOG env var override).

PASS=0
FAIL=0

# --- Test helpers ---
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF -- "${needle}"; then
    echo "  PASS: ${desc}"
    ((PASS += 1))
  else
    echo "  FAIL: ${desc}"
    echo "        expected to find: ${needle}"
    echo "        in log (first 10 lines):"
    echo "${haystack}" | head -10 | sed 's/^/          /'
    ((FAIL += 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((PASS += 1))
  else
    echo "  FAIL: ${desc}"
    echo "        expected: ${expected}"
    echo "        actual:   ${actual}"
    ((FAIL += 1))
  fi
}

# --- Test repo setup ---
# Creates a real git repo with a staged file so git diff --cached works
TMPDIR_TEST="$(mktemp -d)"
REPO_DIR="${TMPDIR_TEST}/testrepo"

setup_repo() {
  rm -rf "${REPO_DIR}"
  mkdir -p "${REPO_DIR}"
  cd "${REPO_DIR}"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  # Create and commit a base file
  echo "#!/usr/bin/env bash" >foo.sh
  git add foo.sh
  git commit -q -m "base" --no-verify
}

# Stage a change to foo.sh and return to original dir
stage_small_change() {
  cd "${REPO_DIR}"
  echo "echo hello" >>foo.sh
  git add foo.sh
  cd - >/dev/null
}

# Stage changes to multiple files (for chunked review path)
stage_large_change() {
  cd "${REPO_DIR}"
  for i in $(seq 1 5); do
    printf '#!/usr/bin/env bash\n# File %d\n' "${i}" >"file${i}.sh"
    for j in $(seq 1 8); do
      echo "echo line_${j}_of_file_${i}" >>"file${i}.sh"
    done
    git add "file${i}.sh"
  done
  cd - >/dev/null
}

# Create mock claude binary with given exit code and stdout output.
# Output is written to a separate file and cat'd by the mock to avoid
# heredoc expansion issues when output contains double-quotes or other
# special characters that would break an inline printf '%s\n' "${output}".
#
# The mock short-circuits on --version so run-review.sh's CLI preflight
# passes quickly (preflight calls `timeout 5 ${CLI} --version` and only
# fails the whole script on exit 124). Without this fast-path, a mock
# configured to exit nonzero would still pass preflight (preflight tolerates
# non-124 exits) but a mock that sleeps — like Test 5's inline sleep mock —
# would hit the 5s timeout and kill the whole test run.
make_mock_claude() {
  local mock_dir="$1" exit_code="$2" output="$3"
  mkdir -p "${mock_dir}"
  printf '%s\n' "${output}" >"${mock_dir}/output.txt"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat "${mock_dir}/output.txt"
exit ${exit_code}
EOF
  chmod +x "${mock_dir}/claude"
}

# Inline trap: restore review.maxLines if set, then remove temp dir.
# REPO_DIR is a script-level variable set above; TMPDIR_TEST likewise.
trap 'cd "${REPO_DIR}" 2>/dev/null && git config --unset review.maxLines 2>/dev/null || true; rm -rf "${TMPDIR_TEST}"' EXIT

# =========================================================
# TEST 1: set -e propagation at call site (single-pass path)
#
# When Claude CLI exits non-zero, run-review.sh should NOT exit silently.
# The REVIEW_LOG must contain the agent error description, not just exit_code.
# (Currently fails because set -e kills the script at CODE_REVIEWER_OUTPUT=$(invoke_agent ...)
#  before the log-writing section at lines 608+ is reached.)
# =========================================================
echo ""
echo "=== Test 1: set -e protection — Claude CLI transient failure (single-pass) ==="

setup_repo
stage_small_change

MOCK1_DIR="${TMPDIR_TEST}/mock1"
make_mock_claude "${MOCK1_DIR}" 1 ""

TEST1_LOG="${TMPDIR_TEST}/test1-review.log"
rm -f "${TEST1_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST1_LOG}" CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST1_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains agent error info (not just bare exit_code: 1)" \
  "agent error" \
  "${log_content}"

# Transient agent failure (both reviewers error) must not block the commit.
# Both produce VERDICT: FAIL (agent error: 1) with no SEVERITY: BLOCKING —
# they should be treated as non-blocking warnings, not genuine rejections.
exit_t1=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST1_LOG}" CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t1=$?
cd - >/dev/null

assert_eq \
  "transient agent failure (both reviewers error) does not block commit" \
  "0" \
  "${exit_t1}"

# =========================================================
# TEST 2: Chunked review path writes output to REVIEW_LOG
#
# When diff > maxLines, perform_chunked_review() runs. Its results (which file
# was reviewed, verdict per file, summary) must appear in REVIEW_LOG.
# (Currently only diff_lines: N (chunked review) + exit_code: N are written.)
# =========================================================
echo ""
echo "=== Test 2: Chunked review log completeness ==="

setup_repo
stage_large_change

MOCK2_DIR="${TMPDIR_TEST}/mock2"
make_mock_claude "${MOCK2_DIR}" 0 "VERDICT: PASS

No blocking issues found."

TEST2_LOG="${TMPDIR_TEST}/test2-review.log"
rm -f "${TEST2_LOG}"

cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST2_LOG}" CLAUDE_CLI="${MOCK2_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST2_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains CHUNKED REVIEW section header" \
  "CHUNKED REVIEW" \
  "${log_content}"

assert_contains \
  "log contains file review count (Reviewed: N/N files)" \
  "Reviewed:" \
  "${log_content}"

# =========================================================
# TEST 3: Agent error on EVERY file in chunked mode blocks the commit (fail-closed)
#
# When Claude CLI fails for a file chunk, that file is SKIPPED (logged as
# skipped due to agent error) rather than counting as a blocking issue in
# its own right. But if EVERY file in the batch is skipped this way,
# reviewed_files ends up at 0 with file_count > 0 — a review that reviewed
# nothing provides no safety signal and must not be reported as a pass.
# Issue #200: previously this fell through to "Chunked review passed (0
# files reviewed)" and returned 0 (fail-open). Now it returns 1.
# =========================================================
echo ""
echo "=== Test 3: Agent error on every file in chunked mode blocks (fail-closed, exit 1) ==="

setup_repo
stage_large_change

MOCK3_DIR="${TMPDIR_TEST}/mock3"
make_mock_claude "${MOCK3_DIR}" 1 "" # Claude exits non-zero (transient failure) on every file

TEST3_LOG="${TMPDIR_TEST}/test3-review.log"
rm -f "${TEST3_LOG}"

exit_code_t3=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST3_LOG}" CLAUDE_CLI="${MOCK3_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_code_t3=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${TEST3_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "chunked review with 0/N files reviewed blocks commit (exit 1) - issue #200" \
  "1" \
  "${exit_code_t3}"

assert_contains \
  "log notes files were skipped due to agent error" \
  "skipped" \
  "${log_content}"

assert_contains \
  "log shows 0 files were reviewed" \
  "Reviewed: 0/" \
  "${log_content}"

# =========================================================
# TEST 3b: Partial skip (some files reviewed) is still non-fatal
#
# Regression guard for #200: the fail-closed behavior above must trigger
# ONLY when reviewed_files is exactly 0. If at least one file was actually
# reviewed (and passed), a mix of skipped + reviewed files must still allow
# the commit through — the fix should not regress the original "one bad
# file doesn't kill the whole batch" behavior.
# =========================================================
echo ""
echo "=== Test 3b: Partial skip (some files reviewed) does not block commit ==="

setup_repo
stage_large_change

MOCK3B_DIR="${TMPDIR_TEST}/mock3b"
mkdir -p "${MOCK3B_DIR}"
# Mock inspects stdin (the per-file review prompt, which embeds the diff)
# to distinguish file1.sh (reviewed, PASS) from all other files (agent error).
cat >"${MOCK3B_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
stdin_content="$(cat)"
if [[ "${stdin_content}" == *"file1.sh"* ]]; then
  echo "VERDICT: PASS"
  echo ""
  echo "No blocking issues found."
  exit 0
fi
exit 1
MOCKEOF
chmod +x "${MOCK3B_DIR}/claude"

TEST3B_LOG="${TMPDIR_TEST}/test3b-review.log"
rm -f "${TEST3B_LOG}"

exit_code_t3b=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST3B_LOG}" CLAUDE_CLI="${MOCK3B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_code_t3b=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content_t3b="$(cat "${TEST3B_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "partial skip (1 reviewed, 4 skipped) still passes (exit 0)" \
  "0" \
  "${exit_code_t3b}"

assert_contains \
  "log shows at least 1 file was reviewed" \
  "Reviewed: 1/" \
  "${log_content_t3b}"

# =========================================================
# TEST 4: Stderr hint on chunked review with genuine blocking failure
#
# When chunked review finds a genuine BLOCKING verdict, stderr should include
# the review.maxLines workaround hint (to guide users who think it's a false positive).
# =========================================================
echo ""
echo "=== Test 4: Stderr hint on chunked review blocking failure ==="

setup_repo
stage_large_change

MOCK4_DIR="${TMPDIR_TEST}/mock4"
make_mock_claude "${MOCK4_DIR}" 0 "VERDICT: FAIL

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: file1.sh:3
DETAILS: Remove the hardcoded credential."

TEST4_LOG="${TMPDIR_TEST}/test4-review.log"
rm -f "${TEST4_LOG}"

stderr_out=""
cd "${REPO_DIR}"
git config review.maxLines 10
stderr_out="$(REVIEW_LOG="${TEST4_LOG}" CLAUDE_CLI="${MOCK4_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>&1 || true)"
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

assert_contains \
  "stderr includes review.maxLines workaround hint" \
  "review.maxLines" \
  "${stderr_out}"

# =========================================================
# TEST 5: review.timeout git config is read by the script
#
# The error message "git config review.timeout 300" is shown on timeout,
# but TIMEOUT_SECONDS was previously hardcoded to 120 and never read
# from git config. Verify that setting review.timeout actually changes
# the timeout value passed to `timeout`.
# =========================================================
echo ""
echo "=== Test 5: review.timeout git config is honoured ==="

setup_repo
stage_small_change

# Create a mock that sleeps longer than a 1s timeout then outputs PASS.
# If review.timeout=1 is honoured, the agent will be killed and we get a timeout verdict.
# If review.timeout is ignored (TIMEOUT_SECONDS=120 hardcoded), the mock would finish in ~2s.
MOCK5_DIR="${TMPDIR_TEST}/mock5"
mkdir -p "${MOCK5_DIR}"
# Fast-path --version so the CLI preflight (timeout 5) doesn't kill us before
# the real test scenario. The real invocation (without --version) still sleeps.
cat >"${MOCK5_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
sleep 5
echo "VERDICT: PASS"
echo "No blocking issues found."
MOCKEOF
chmod +x "${MOCK5_DIR}/claude"

TEST5_LOG="${TMPDIR_TEST}/test5-review.log"
rm -f "${TEST5_LOG}"

cd "${REPO_DIR}"
git config review.timeout 1
REVIEW_LOG="${TEST5_LOG}" CLAUDE_CLI="${MOCK5_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.timeout 2>/dev/null || true
cd - >/dev/null

log_content5="$(cat "${TEST5_LOG}" 2>/dev/null || echo "")"

# If the config is honoured, the 1s timeout fires and the log records the timeout
assert_contains \
  "review.timeout=1 causes timeout to fire (config is read)" \
  "timeout" \
  "${log_content5}"

# =========================================================
# TEST 6: make_mock_claude handles double-quotes in output
#
# make_mock_claude uses an unquoted heredoc (<<EOF), so ${output} is expanded
# at generation time. If output contains double-quotes, the generated
# printf '%s\n' "${output}" line gets unbalanced quotes and the mock script
# fails with a syntax error.
# Fix: write output to a separate file and have the mock cat it.
# =========================================================
echo ""
echo "=== Test 6: make_mock_claude handles double-quotes in output ==="

MOCK6_DIR="${TMPDIR_TEST}/mock6"
# Single-quoted here to prevent shell expansion of the double-quotes
make_mock_claude "${MOCK6_DIR}" 0 'VERDICT: FAIL (agent error: "timeout")'

mock6_out="$("${MOCK6_DIR}/claude" 2>/dev/null || true)"

assert_contains \
  "mock correctly outputs string with embedded double-quotes" \
  'VERDICT: FAIL (agent error: "timeout")' \
  "${mock6_out}"

# =========================================================
# TEST 7: REVIEW_LOG env var overrides production log path
#
# run-review.sh hardcodes REVIEW_LOG="${HOME}/.claude/last-review-result.log".
# Tests should be able to pass REVIEW_LOG as an env var to redirect log output
# to a temporary path, preventing test runs from clobbering the production log.
# =========================================================
echo ""
echo "=== Test 7: REVIEW_LOG env var overrides production log path ==="

setup_repo
stage_small_change

MOCK7_DIR="${TMPDIR_TEST}/mock7"
make_mock_claude "${MOCK7_DIR}" 0 "VERDICT: PASS

No blocking issues found."

ISOLATED_LOG="${TMPDIR_TEST}/isolated-review.log"
rm -f "${ISOLATED_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${ISOLATED_LOG}" CLAUDE_CLI="${MOCK7_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

isolated_log_content="$(cat "${ISOLATED_LOG}" 2>/dev/null || echo "")"
assert_contains \
  "isolated log is written when REVIEW_LOG env var is set" \
  "exit_code:" \
  "${isolated_log_content}"

# =========================================================
# TEST 8: Empty reviewer output (exit 0) does not block commit
#
# If invoke_agent exits 0 but produces no stdout, CODE_REVIEWER_OUTPUT="".
# Both PASS and FAIL greps fail, falling to "Could not parse verdict" -> exit 1.
# Fix: add empty-output guard after || true:
#   [[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: ...)"
# This synthesises a transient-error verdict that the existing non-blocking check
# handles correctly, resulting in exit 0.
# =========================================================
echo ""
echo "=== Test 8: empty reviewer output (exit 0) does not block commit ==="

setup_repo
stage_small_change

MOCK8_DIR="${TMPDIR_TEST}/mock8"
mkdir -p "${MOCK8_DIR}"
cat >"${MOCK8_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
# Fast-path --version so CLI preflight passes (see make_mock_claude).
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
# Exits successfully but produces no output (simulates a silent agent failure)
exit 0
MOCKEOF
chmod +x "${MOCK8_DIR}/claude"

TEST8_LOG="${TMPDIR_TEST}/test8-review.log"
exit_t8=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST8_LOG}" CLAUDE_CLI="${MOCK8_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t8=$?
cd - >/dev/null

assert_eq \
  "empty reviewer output (exit 0) does not block commit" \
  "0" \
  "${exit_t8}"

# =========================================================
# TEST 9: Chunked-mode timeout verdicts are counted as skips, not warnings —
# and an all-timeout batch is fail-closed (issue #200)
#
# invoke_agent emits two distinct synthetic verdicts on transient failure:
#   - "VERDICT: FAIL (timeout)"       — exit 124 from `timeout` command
#   - "VERDICT: FAIL (agent error: N)" — any other non-zero exit
# The parallel aggregate loop greps for "VERDICT: FAIL (" so both are
# classified as skips (non-fatal per-file — they don't count toward
# blocking_count). Regression test: previously the grep was "VERDICT: FAIL
# (agent error", which missed the timeout case and miscounted timeouts as
# warnings. Caught by Seer on PR #128; see issue #129.
#
# Since every file in this batch times out, reviewed_files ends up at 0 —
# per issue #200 this must now block the commit (exit 1), not pass silently.
# =========================================================
echo ""
echo "=== Test 9: chunked-mode timeout verdicts classified as skips ==="

setup_repo
stage_large_change

# Mock emits a timeout-style synthetic verdict (matches what invoke_agent
# produces on real timeout) instead of actual sleep — faster, deterministic.
MOCK9_DIR="${TMPDIR_TEST}/mock9"
make_mock_claude "${MOCK9_DIR}" 0 "VERDICT: FAIL (timeout)"

TEST9_LOG="${TMPDIR_TEST}/test9-review.log"
rm -f "${TEST9_LOG}"

exit_t9=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST9_LOG}" CLAUDE_CLI="${MOCK9_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t9=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content9="$(cat "${TEST9_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "chunked all-timeout (0/N reviewed) blocks commit (exit 1) - issue #200" \
  "1" \
  "${exit_t9}"

assert_contains \
  "log notes files were skipped (not counted as warnings)" \
  "skipped" \
  "${log_content9}"

# =========================================================
# TEST 10: sync/* branches skip review regardless of diff size
#
# Sync commits aggregate content already reviewed in the source repo.
# Running the size cap against them produces false blocks, so `sync/*`
# branches must exit 0 without invoking the reviewer.
# =========================================================
echo ""
echo "=== Test 10: sync/* branch skips review even when diff > skipThreshold ==="

setup_repo
cd "${REPO_DIR}"
git checkout -q -b "sync/2026-04-23-test"
# Stage a diff well above the default 2500-line skipThreshold so the
# test would hit the "BLOCKING: Diff too large" path if the sync-skip
# logic regressed.
for i in $(seq 1 3000); do echo "line_${i}_content" >>bigfile.sh; done
git add bigfile.sh
cd - >/dev/null

MOCK10_DIR="${TMPDIR_TEST}/mock10"
# Mock should never be invoked — if run-review.sh calls it, the sync skip
# broke and the test's "skipped: sync branch" assertion will also fail.
make_mock_claude "${MOCK10_DIR}" 1 "MOCK SHOULD NOT RUN"

TEST10_LOG="${TMPDIR_TEST}/test10-review.log"
rm -f "${TEST10_LOG}"

exit_t10=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST10_LOG}" CLAUDE_CLI="${MOCK10_DIR}/claude" \
  bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t10=$?
cd - >/dev/null

assert_eq \
  "sync branch exits 0 (review skipped)" \
  "0" \
  "${exit_t10}"

log_content10="$(cat "${TEST10_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log notes sync-branch skip reason" \
  "skipped: sync branch" \
  "${log_content10}"

# =========================================================
# TEST 11: "VERDICT: Revise" is treated as FAIL (blocking)
#
# Reviewers sometimes emit "VERDICT: Revise" instead of "VERDICT: FAIL".
# The script must treat Revise as a synonym for FAIL: when combined with
# SEVERITY: BLOCKING, it should block the commit (exit 1).
# =========================================================
echo ""
echo "=== Test 11: VERDICT: Revise treated as blocking FAIL ==="

setup_repo
stage_small_change

MOCK11_DIR="${TMPDIR_TEST}/mock11"
make_mock_claude "${MOCK11_DIR}" 0 "VERDICT: Revise

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST11_LOG="${TMPDIR_TEST}/test11-review.log"
rm -f "${TEST11_LOG}"

exit_t11=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST11_LOG}" CLAUDE_CLI="${MOCK11_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t11=$?
cd - >/dev/null

assert_eq \
  "VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t11}"

log_content11="$(cat "${TEST11_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log records FAIL verdict (Revise normalized to FAIL)" \
  "FAIL" \
  "${log_content11}"

# Mock that returns different output depending on which agent is invoked.
# The single-pass path calls: --agent "<agent_name>" ... so $2 is the agent
# name. Used to test the code-reviewer / adversarial-reviewer asymmetry
# fixed in issue #199.
make_mock_claude_by_agent() {
  local mock_dir="$1" cr_output="$2" ar_output="$3"
  mkdir -p "${mock_dir}"
  printf '%s\n' "${cr_output}" >"${mock_dir}/cr_output.txt"
  printf '%s\n' "${ar_output}" >"${mock_dir}/ar_output.txt"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
if [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.txt"
else
  cat "${mock_dir}/cr_output.txt"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# =========================================================
# TEST 12: adversarial-reviewer WARNING-only FAIL is non-blocking (issue #199)
#
# Before the fix, adversarial-reviewer blocked on ANY non-transient FAIL
# verdict regardless of severity, while code-reviewer only blocked on
# SEVERITY: BLOCKING. This asymmetry meant a warnings-only adversarial FAIL
# rejected commits that code-reviewer's own rule would have allowed through.
# Fix: gate adversarial the same way — only SEVERITY: BLOCKING blocks.
# =========================================================
echo ""
echo "=== Test 12: adversarial-reviewer WARNING-only FAIL is non-blocking ==="

setup_repo
stage_small_change

MOCK12_DIR="${TMPDIR_TEST}/mock12"
make_mock_claude_by_agent "${MOCK12_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Unpin needs rationale
SEVERITY: WARNING
LOCATION: settings.json:1
DETAILS: Document why the pin was removed."

TEST12_LOG="${TMPDIR_TEST}/test12-review.log"
rm -f "${TEST12_LOG}"

exit_t12=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST12_LOG}" CLAUDE_CLI="${MOCK12_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t12=$?
cd - >/dev/null

assert_eq \
  "adversarial WARNING-only FAIL does not block commit (exit 0) - issue #199" \
  "0" \
  "${exit_t12}"

# =========================================================
# TEST 13: adversarial-reviewer BLOCKING FAIL still blocks (issue #199)
#
# The symmetry fix must not make adversarial-reviewer toothless — a genuine
# SEVERITY: BLOCKING verdict from adversarial-reviewer must still reject
# the commit, exactly like code-reviewer's own BLOCKING gate.
# =========================================================
echo ""
echo "=== Test 13: adversarial-reviewer BLOCKING FAIL still blocks commit ==="

setup_repo
stage_small_change

MOCK13_DIR="${TMPDIR_TEST}/mock13"
make_mock_claude_by_agent "${MOCK13_DIR}" \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential."

TEST13_LOG="${TMPDIR_TEST}/test13-review.log"
rm -f "${TEST13_LOG}"

exit_t13=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST13_LOG}" CLAUDE_CLI="${MOCK13_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t13=$?
cd - >/dev/null

assert_eq \
  "adversarial BLOCKING FAIL still blocks commit (exit 1) - issue #199" \
  "1" \
  "${exit_t13}"

# =========================================================
# TEST 14: Empty/template-only commit message does not crash the script
# (issue #148)
#
# _read_commit_message's `grep -v '^#' ... | awk ...` pipeline exits 1 (no
# output) when the source file contains only comment lines. Under
# `set -euo pipefail`, without a `|| true` guard on the assignment, this
# would abort the whole script. Exercised via --message-file (the highest-
# priority source, checked unconditionally regardless of REVIEW_MODE).
# =========================================================
echo ""
echo "=== Test 14: template-only commit message does not crash the script ==="

setup_repo
stage_small_change

TEMPLATE_MSG_FILE="${TMPDIR_TEST}/template-only-msg.txt"
printf '# Please enter the commit message\n# Lines starting with # are ignored\n' >"${TEMPLATE_MSG_FILE}"

MOCK14_DIR="${TMPDIR_TEST}/mock14"
make_mock_claude "${MOCK14_DIR}" 0 "VERDICT: PASS

No blocking issues found."

TEST14_LOG="${TMPDIR_TEST}/test14-review.log"
rm -f "${TEST14_LOG}"

exit_t14=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST14_LOG}" CLAUDE_CLI="${MOCK14_DIR}/claude" \
  bash "${SUBJECT}" "--message-file=${TEMPLATE_MSG_FILE}" < <(git diff --cached || true) 2>/dev/null || exit_t14=$?
cd - >/dev/null

log_content14="$(cat "${TEST14_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "template-only commit message does not abort the script (exit 0)" \
  "0" \
  "${exit_t14}"

assert_contains \
  "script ran to completion (exit_code recorded in log)" \
  "exit_code:" \
  "${log_content14}"

# =========================================================
# TEST 15: Codebase mode - stderr noise does not corrupt VERDICT parsing
# (issue #89)
#
# CODEBASE_OUTPUT previously captured stdout+stderr together via 2>&1, so
# any stderr noise (CLI upgrade notices, deprecation warnings) could land
# in the text that `grep -q "VERDICT:"` parses. Fix: stderr is now routed
# to its own temp file, separate from CODEBASE_OUTPUT. Regression test:
# a mock that emits noise on stderr AND a clean PASS verdict on stdout
# must still parse as PASS (exit 0), not be corrupted by the noise.
# =========================================================
echo ""
echo "=== Test 15: codebase mode - stderr noise does not corrupt VERDICT parsing ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK15_DIR="${TMPDIR_TEST}/mock15"
mkdir -p "${MOCK15_DIR}"
cat >"${MOCK15_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
# Simulate CLI noise (upgrade notice, deprecation warning) on stderr,
# interleaved with a clean VERDICT on stdout.
echo "warning: a new version of the CLI is available" >&2
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
echo "deprecation notice: some flag will be removed" >&2
MOCKEOF
chmod +x "${MOCK15_DIR}/claude"

TEST15_LOG="${TMPDIR_TEST}/test15-review.log"
rm -f "${TEST15_LOG}"

exit_t15=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST15_LOG}" CLAUDE_CLI="${MOCK15_DIR}/claude" \
  bash "${SUBJECT}" --mode=codebase 2>/dev/null || exit_t15=$?
cd - >/dev/null

log_content15="$(cat "${TEST15_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "codebase mode PASS verdict is not corrupted by stderr noise (exit 0)" \
  "0" \
  "${exit_t15}"

assert_contains \
  "log records codebase PASS verdict" \
  "codebase:" \
  "${log_content15}"

# =========================================================
# TEST 16: EXIT trap cleans up DIFF_TMPFILE and _codebase_err (issue #90)
# — static guard
#
# Codebase mode writes the diff to a mktemp'd DIFF_TMPFILE so the agent can
# re-Read it, and (per #89) captures stderr in a separate mktemp'd
# _codebase_err. If the script is killed before their explicit `rm -f`
# cleanup lines run, both leak in $TMPDIR. This is only observable via
# SIGTERM/SIGKILL timing, which isn't practical to assert deterministically
# in this harness — instead this is a static regression guard: both must be
# listed in the EXIT trap's cleanup alongside the other known temp
# artifacts. (Caught by adversarial-reviewer during local review: the first
# pass of the #89 fix added _codebase_err's mktemp/rm but missed the trap.)
# =========================================================
echo ""
echo "=== Test 16: EXIT trap includes DIFF_TMPFILE and _codebase_err cleanup ==="

trap_line="$(grep -m1 "^trap '_ec=\$?;" "${SUBJECT}")"

assert_contains \
  "EXIT trap cleanup references DIFF_TMPFILE" \
  "DIFF_TMPFILE" \
  "${trap_line}"

assert_contains \
  "EXIT trap cleanup references _codebase_err" \
  "_codebase_err" \
  "${trap_line}"

# =========================================================
# TEST 17: Permission-only diff is still correctly skipped (issues #166, #171)
#
# The empty-diff / no-code-changes check was rewritten from
# `echo "${DIFF}" | grep -qE ...` to a here-string form to eliminate a
# SIGPIPE race on large diffs (grep exiting before echo finishes writing
# could make the pipeline's exit status echo's 141 instead of grep's real
# result under pipefail). Regression test: the intended behavior — skipping
# review when the diff contains no `+`/`-` code-content lines (e.g. a pure
# mode/permission change) — must still work after the rewrite.
# =========================================================
echo ""
echo "=== Test 17: permission-only diff is skipped (no code changes) ==="

setup_repo
cd "${REPO_DIR}"
chmod +x foo.sh
git add foo.sh
cd - >/dev/null

MOCK17_DIR="${TMPDIR_TEST}/mock17"
# Mock should never be invoked — if run-review.sh calls it, the empty-diff
# skip broke and the exit-code / log assertions below will also fail.
make_mock_claude "${MOCK17_DIR}" 1 "MOCK SHOULD NOT RUN"

TEST17_LOG="${TMPDIR_TEST}/test17-review.log"
rm -f "${TEST17_LOG}"

exit_t17=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST17_LOG}" CLAUDE_CLI="${MOCK17_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t17=$?
cd - >/dev/null

assert_eq \
  "permission-only diff exits 0 (review skipped, agent never invoked)" \
  "0" \
  "${exit_t17}"

log_content17="$(cat "${TEST17_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log notes permission/metadata-only skip reason" \
  "skipped: permission/metadata only" \
  "${log_content17}"

# =========================================================
# TEST 18: "VERDICT: Revise" is treated as blocking FAIL in chunked mode
# (issue #173)
#
# Test 11 covers the single-pass (small diff, no --mode) path. This mirrors
# Test 3/Test 4's chunked-mode setup (stage_large_change + review.maxLines=10
# to force chunking) with a mock that returns VERDICT: Revise + SEVERITY:
# BLOCKING for every file. The chunked aggregate loop must normalize Revise
# to FAIL and block the commit (exit 1), matching the single-pass behavior.
# =========================================================
echo ""
echo "=== Test 18: VERDICT: Revise treated as blocking FAIL (chunked mode) ==="

setup_repo
stage_large_change

MOCK18_DIR="${TMPDIR_TEST}/mock18"
make_mock_claude "${MOCK18_DIR}" 0 "VERDICT: Revise

ISSUE: Hardcoded secret
SEVERITY: BLOCKING
LOCATION: file1.sh:3
DETAILS: Remove the hardcoded credential."

TEST18_LOG="${TMPDIR_TEST}/test18-review.log"
rm -f "${TEST18_LOG}"

exit_t18=0
cd "${REPO_DIR}"
git config review.maxLines 10
REVIEW_LOG="${TEST18_LOG}" CLAUDE_CLI="${MOCK18_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t18=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

assert_eq \
  "chunked-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t18}"

log_content18="$(cat "${TEST18_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "chunked-mode log records blocking issue count (Revise normalized to FAIL/blocking)" \
  "Blocking: 5" \
  "${log_content18}"

# =========================================================
# TEST 19: "VERDICT: Revise" is treated as blocking FAIL in full-diff mode
# (issue #173); also exercises model logging (issue #159)
#
# Mirrors Test 15's invocation pattern (commit a change, then pipe
# `git diff main~1 main` in with --mode=full-diff) with a mock that returns
# VERDICT: Revise + SEVERITY: BLOCKING. The full-diff path must normalize
# Revise to FAIL and block (exit 1). Also asserts the "model:" log line
# introduced for issue #159 appears, since full-diff mode exits internally
# before the previously-dead model logging at the end of the script.
# =========================================================
echo ""
echo "=== Test 19: VERDICT: Revise treated as blocking FAIL (full-diff mode) ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK19_DIR="${TMPDIR_TEST}/mock19"
make_mock_claude "${MOCK19_DIR}" 0 "VERDICT: Revise

ISSUE: Cross-file inconsistency
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Fix the cross-file mismatch."

TEST19_LOG="${TMPDIR_TEST}/test19-review.log"
rm -f "${TEST19_LOG}"

exit_t19=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST19_LOG}" CLAUDE_CLI="${MOCK19_DIR}/claude" \
  bash "${SUBJECT}" --mode=full-diff 2>/dev/null || exit_t19=$?
cd - >/dev/null

assert_eq \
  "full-diff-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t19}"

log_content19="$(cat "${TEST19_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "full-diff-mode log records FAIL (blocking) verdict (Revise normalized to FAIL)" \
  "full-diff: FAIL (blocking)" \
  "${log_content19}"

assert_contains \
  "full-diff-mode log records resolved model (issue #159)" \
  "model:" \
  "${log_content19}"

# =========================================================
# TEST 20: "VERDICT: Revise" is treated as blocking FAIL in codebase mode
# (issue #173); also exercises model logging (issue #159)
#
# Mirrors Test 15's invocation pattern with --mode=codebase and a mock that
# returns VERDICT: Revise + SEVERITY: BLOCKING. The codebase path must
# normalize Revise to FAIL and block (exit 1), and the "model:" log line
# (issue #159) must appear since codebase mode also exits internally.
# =========================================================
echo ""
echo "=== Test 20: VERDICT: Revise treated as blocking FAIL (codebase mode) ==="

setup_repo
stage_small_change
cd "${REPO_DIR}"
git add foo.sh
git commit -q -m "stage a change" --no-verify
cd - >/dev/null

MOCK20_DIR="${TMPDIR_TEST}/mock20"
make_mock_claude "${MOCK20_DIR}" 0 "VERDICT: Revise

ISSUE: Field contract violation
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Fix the renamed field reference."

TEST20_LOG="${TMPDIR_TEST}/test20-review.log"
rm -f "${TEST20_LOG}"

exit_t20=0
cd "${REPO_DIR}"
git diff main~1 main | REVIEW_LOG="${TEST20_LOG}" CLAUDE_CLI="${MOCK20_DIR}/claude" \
  bash "${SUBJECT}" --mode=codebase 2>/dev/null || exit_t20=$?
cd - >/dev/null

assert_eq \
  "codebase-mode VERDICT: Revise with BLOCKING severity blocks commit (exit 1)" \
  "1" \
  "${exit_t20}"

log_content20="$(cat "${TEST20_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "codebase-mode log records FAIL (blocking) verdict (Revise normalized to FAIL)" \
  "codebase: FAIL (blocking)" \
  "${log_content20}"

assert_contains \
  "codebase-mode log records resolved model (issue #159)" \
  "model:" \
  "${log_content20}"

# =========================================================
# TEST 21: review.model git config overrides the default model (issue #160)
#
# run-review.sh reads review.model via git config and passes it through
# MODEL_ARGS=(--model "${REVIEW_MODEL}") to the CLI invocation. There was
# previously no test exercising this override path. This mock records its
# full invocation argv (mirroring how make_mock_claude_by_agent inspects
# $2 for the agent name) so the test can assert that --model plus the
# configured value actually reached the CLI's argv.
# =========================================================
echo ""
echo "=== Test 21: review.model git config overrides default model ==="

setup_repo
stage_small_change

MOCK21_DIR="${TMPDIR_TEST}/mock21"
mkdir -p "${MOCK21_DIR}"
MOCK21_ARGS_FILE="${MOCK21_DIR}/invocation-args.txt"
rm -f "${MOCK21_ARGS_FILE}"
cat >"${MOCK21_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK21_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK21_DIR}/claude"

TEST21_LOG="${TMPDIR_TEST}/test21-review.log"
rm -f "${TEST21_LOG}"

cd "${REPO_DIR}"
git config review.model "some-custom-model-id"
REVIEW_LOG="${TEST21_LOG}" CLAUDE_CLI="${MOCK21_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.model 2>/dev/null || true
cd - >/dev/null

invocation_args="$(cat "${MOCK21_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "custom review.model value is passed through to the CLI invocation (issue #160)" \
  "--model some-custom-model-id" \
  "${invocation_args}"

# =========================================================
# TEST 22: CODE_REVIEWER_AGENT default resolves to the actually-installed
# fully-qualified agent name (issue #209, and its regression in #212)
#
# The real installed agent ID doubles the plugin name — "comprehensive-review:
# comprehensive-review-code-reviewer" — per the comprehensive-review plugin's
# agents/code-reviewer.md frontmatter. #212 mistakenly "fixed" the default to
# the bare-looking "comprehensive-review:code-reviewer", which does not match
# any installed agent, so run-review.sh's code-reviewer pass silently errored
# on every commit again. Assert the --agent value that actually reaches the
# CLI invocation matches the real installed agent ID (verify with
# `claude --agent bogus -p`, which lists installed agents in its error).
# =========================================================
echo ""
echo "=== Test 22: CODE_REVIEWER_AGENT default matches installed agent ID (issue #209) ==="

setup_repo
stage_small_change

MOCK22_DIR="${TMPDIR_TEST}/mock22"
mkdir -p "${MOCK22_DIR}"
MOCK22_ARGS_FILE="${MOCK22_DIR}/invocation-args.txt"
rm -f "${MOCK22_ARGS_FILE}"
cat >"${MOCK22_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK22_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK22_DIR}/claude"

TEST22_LOG="${TMPDIR_TEST}/test22-review.log"
rm -f "${TEST22_LOG}"

cd "${REPO_DIR}"
git config --unset review.codeReviewerAgent 2>/dev/null || true
REVIEW_LOG="${TEST22_LOG}" CLAUDE_CLI="${MOCK22_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

invocation_args22="$(cat "${MOCK22_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "default CODE_REVIEWER_AGENT resolves to installed agent ID (issue #209)" \
  "--agent comprehensive-review:comprehensive-review-code-reviewer " \
  "${invocation_args22}"

# =========================================================
# TEST 23: review.adversarialModel git config overrides the adversarial-
# reviewer model independently of review.model / REVIEW_MODE (issue #235)
#
# adversarial-reviewer previously rode the same REVIEW_MODEL as code-reviewer
# via a shared MODEL_ARGS global (Haiku on commit-mode, the highest-frequency
# path). run-review.sh now resolves a separate ADVERSARIAL_MODEL_ARGS,
# defaulting to claude-sonnet-4-6 regardless of mode, overridable via
# `git config review.adversarialModel`. invoke_agent() takes model args as a
# per-call parameter instead of reading a shared global, so this test asserts
# (a) code-reviewer still gets the mode-based default (Haiku, unaffected by
# the adversarialModel override) and (b) adversarial-reviewer gets the
# configured override, in the same commit-mode run.
# =========================================================
echo ""
echo "=== Test 23: review.adversarialModel overrides adversarial-reviewer model independently (issue #235) ==="

setup_repo
stage_small_change

MOCK23_DIR="${TMPDIR_TEST}/mock23"
mkdir -p "${MOCK23_DIR}"
MOCK23_ARGS_FILE="${MOCK23_DIR}/invocation-args.txt"
rm -f "${MOCK23_ARGS_FILE}"
cat >"${MOCK23_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
printf '%s\n' "\$*" >>"${MOCK23_ARGS_FILE}"
echo "VERDICT: PASS"
echo ""
echo "No blocking issues found."
exit 0
EOF
chmod +x "${MOCK23_DIR}/claude"

TEST23_LOG="${TMPDIR_TEST}/test23-review.log"
rm -f "${TEST23_LOG}"

cd "${REPO_DIR}"
git config review.adversarialModel "some-adversarial-model-id"
REVIEW_LOG="${TEST23_LOG}" CLAUDE_CLI="${MOCK23_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
git config --unset review.adversarialModel 2>/dev/null || true
cd - >/dev/null

invocation_args23="$(cat "${MOCK23_ARGS_FILE}" 2>/dev/null || echo "")"

assert_contains \
  "configured review.adversarialModel reaches the adversarial-reviewer CLI invocation (issue #235)" \
  "--agent adversarial-reviewer -p --model some-adversarial-model-id" \
  "${invocation_args23}"

assert_contains \
  "code-reviewer still uses its own mode-based default model, unaffected by review.adversarialModel (issue #235)" \
  "--agent comprehensive-review:comprehensive-review-code-reviewer -p --model claude-haiku-4-5-20251001" \
  "${invocation_args23}"

# =========================================================
# TEST 24: extract_file_header_context surfaces stated scope
# (dev-env#35 — code-reviewer flagged Linux portability on a script whose
# header explicitly says "macOS-only, not intended for Linux/CI" because
# the diff-only prompt never showed that line)
# =========================================================
echo ""
echo "=== Test 24: file header context is extracted and injected into prompt ==="

setup_repo
cd "${REPO_DIR}"
cat >scoped.sh <<'SCRIPT'
#!/usr/bin/env bash
# macOS-only: uses BSD sed (`sed -i ''`). Operator script for this user's
# own machines, not intended for Linux/CI.
echo "hello"
SCRIPT
git add scoped.sh
cd - >/dev/null
stage_small_change

MOCK24_DIR="${TMPDIR_TEST}/mock24"
# Mock records the prompt it received so the test can assert on prompt content.
mkdir -p "${MOCK24_DIR}"
cat >"${MOCK24_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK24_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK24_DIR}/claude"
rm -f "${MOCK24_DIR}/received_prompt.txt"

TEST24_LOG="${TMPDIR_TEST}/test24-review.log"
rm -f "${TEST24_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST24_LOG}" CLAUDE_CLI="${MOCK24_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received="$(cat "${MOCK24_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "prompt includes the file's stated macOS-only scope (dev-env#35)" \
  "not intended for Linux/CI" \
  "${received}"

# =========================================================
# TEST 25: round-over-round feedback is injected on a retry after a FAIL
# (dev-env#35 — code-reviewer re-litigated already-addressed findings
# with a different remedy each round because each --no-session-persistence
# call started from zero)
# =========================================================
echo ""
echo "=== Test 25: prior-round FAIL feedback is injected into the retry prompt ==="

setup_repo
stage_small_change

MOCK25A_DIR="${TMPDIR_TEST}/mock25a"
make_mock_claude "${MOCK25A_DIR}" 0 "VERDICT: FAIL

ISSUE: Hardcoded path
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Use \$HOME instead of a literal path."

TEST25_LOG="${TMPDIR_TEST}/test25-review.log"
rm -f "${TEST25_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25A_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# Second round: same branch, same changed file (foo.sh) — simulates a retry
# after an edit that didn't fully address round 1's finding. Mock records
# the prompt it receives.
MOCK25B_DIR="${TMPDIR_TEST}/mock25b"
mkdir -p "${MOCK25B_DIR}"
cat >"${MOCK25B_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK25B_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK25B_DIR}/claude"
rm -f "${MOCK25B_DIR}/received_prompt.txt"

cd "${REPO_DIR}"
echo "echo round2edit" >>foo.sh
git add foo.sh
REVIEW_LOG="${TEST25_LOG}" CLAUDE_CLI="${MOCK25B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received25="$(cat "${MOCK25B_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

assert_contains \
  "retry prompt includes round 1's BLOCKING finding (dev-env#35)" \
  "Hardcoded path" \
  "${received25}"

# Like make_mock_claude_by_agent, but differentiates three agent identities.
# The real arbiter call reuses agent_name="adversarial-reviewer" (see
# run-review.sh), so $2 alone cannot distinguish it from the real
# adversarial-reviewer call — both would match "*adversarial*". Instead,
# detect the arbiter call by its distinctive prompt content (piped on
# stdin): the arbiter prompt contains "CODE-REVIEWER VERDICT" as a section
# header, which never appears in the normal per-commit review prompt. Check
# stdin content FIRST, before falling back to $2, so it takes precedence
# over the "*adversarial*" branch.
make_mock_claude_three_way() {
  local mock_dir="$1" cr_output="$2" ar_output="$3" arbiter_output="$4"
  mkdir -p "${mock_dir}"
  printf '%s\n' "${cr_output}" >"${mock_dir}/cr_output.txt"
  printf '%s\n' "${ar_output}" >"${mock_dir}/ar_output.txt"
  printf '%s\n' "${arbiter_output}" >"${mock_dir}/arbiter_output.txt"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
_stdin_input="\$(cat)"
if echo "\${_stdin_input}" | grep -q "CODE-REVIEWER VERDICT"; then
  cat "${mock_dir}/arbiter_output.txt"
elif [[ "\$2" == *adversarial* ]]; then
  cat "${mock_dir}/ar_output.txt"
else
  cat "${mock_dir}/cr_output.txt"
fi
exit 0
EOF
  chmod +x "${mock_dir}/claude"
}

# =========================================================
# TEST 26: arbiter overrides a code-reviewer BLOCKING FAIL when it sides
# with adversarial-reviewer's PASS (dev-env#35)
# =========================================================
echo ""
echo "=== Test 26: arbiter can override code-reviewer FAIL when adversarial-reviewer PASSes ==="

setup_repo
stage_small_change

MOCK26_DIR="${TMPDIR_TEST}/mock26"
make_mock_claude_three_way "${MOCK26_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. Script header already states macOS-only scope." \
  "VERDICT: PASS

The adversarial-reviewer is correct: the script's header comment already
documents macOS-only scope, so code-reviewer's finding does not apply."

TEST26_LOG="${TMPDIR_TEST}/test26-review.log"
rm -f "${TEST26_LOG}"

exit_t26=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST26_LOG}" CLAUDE_CLI="${MOCK26_DIR}/claude" GH_ISSUE_FILING_DISABLED=1 bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t26=$?
cd - >/dev/null

assert_eq \
  "arbiter PASS overrides code-reviewer BLOCKING FAIL (exit 0) - dev-env#35" \
  "0" \
  "${exit_t26}"

# =========================================================
# TEST 27: arbiter siding with code-reviewer still blocks the commit
# =========================================================
echo ""
echo "=== Test 27: arbiter siding with code-reviewer still blocks commit ==="

setup_repo
stage_small_change

MOCK27_DIR="${TMPDIR_TEST}/mock27"
make_mock_claude_three_way "${MOCK27_DIR}" \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Remove the hardcoded credential." \
  "VERDICT: PASS

No blocking issues found." \
  "VERDICT: FAIL

ISSUE: Hardcoded credential
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: code-reviewer is correct; adversarial-reviewer missed this."

TEST27_LOG="${TMPDIR_TEST}/test27-review.log"
rm -f "${TEST27_LOG}"

exit_t27=0
cd "${REPO_DIR}"
REVIEW_LOG="${TEST27_LOG}" CLAUDE_CLI="${MOCK27_DIR}/claude" GH_ISSUE_FILING_DISABLED=1 bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || exit_t27=$?
cd - >/dev/null

assert_eq \
  "arbiter siding with code-reviewer still blocks commit (exit 1)" \
  "1" \
  "${exit_t27}"

test27_log_content="$(cat "${TEST27_LOG}")"
assert_contains \
  "arbiter ran for test 27 (not just coincidental pre-existing block)" \
  "=== ARBITER" \
  "${test27_log_content}"

# =========================================================
# TEST 28: arbiter-resolved false positive does not survive into the next
# commit's round history (dev-env#35 — write_round_feedback runs based on
# CODE_REVIEWER_VERDICT alone, before the arbiter has a chance to overrule
# it, so the PASS path must explicitly clear what was already written)
# =========================================================
echo ""
echo "=== Test 28: arbiter PASS clears the round-history entry code-reviewer wrote before it ran ==="

setup_repo
stage_small_change

MOCK28A_DIR="${TMPDIR_TEST}/mock28a"
make_mock_claude_three_way "${MOCK28A_DIR}" \
  "VERDICT: FAIL

ISSUE: Missing Linux platform guard
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: Add a runtime OS check." \
  "VERDICT: PASS

No blocking issues found. Script header already states macOS-only scope." \
  "VERDICT: PASS

The adversarial-reviewer is correct: the script's header comment already
documents macOS-only scope, so code-reviewer's finding does not apply."

TEST28_LOG="${TMPDIR_TEST}/test28-review.log"
rm -f "${TEST28_LOG}"

cd "${REPO_DIR}"
REVIEW_LOG="${TEST28_LOG}" CLAUDE_CLI="${MOCK28A_DIR}/claude" GH_ISSUE_FILING_DISABLED=1 bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

# Second commit on the same branch+file-set. If round-history wasn't
# cleared, this retry's prompt would carry forward the already-resolved
# "Missing Linux platform guard" finding as PRIOR ROUND FEEDBACK.
MOCK28B_DIR="${TMPDIR_TEST}/mock28b"
mkdir -p "${MOCK28B_DIR}"
cat >"${MOCK28B_DIR}/claude" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  echo "mock-claude 0.0.0-test"
  exit 0
fi
cat >> "${MOCK28B_DIR}/received_prompt.txt"
echo "VERDICT: PASS

No blocking issues found."
exit 0
EOF
chmod +x "${MOCK28B_DIR}/claude"
rm -f "${MOCK28B_DIR}/received_prompt.txt"

cd "${REPO_DIR}"
echo "echo round2edit" >>foo.sh
git add foo.sh
REVIEW_LOG="${TEST28_LOG}" CLAUDE_CLI="${MOCK28B_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached || true) 2>/dev/null || true
cd - >/dev/null

received28="$(cat "${MOCK28B_DIR}/received_prompt.txt" 2>/dev/null || echo "")"

contains_stale_finding="false"
if [[ "${received28}" == *"Missing Linux platform guard"* ]]; then
  contains_stale_finding="true"
fi

assert_eq \
  "arbiter-resolved false positive does not resurface in next commit's prompt (dev-env#35)" \
  "false" \
  "${contains_stale_finding}"

# =========================================================
# Summary
# =========================================================
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed (of 48 assertions)"
echo "======================================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
