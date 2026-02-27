#!/usr/bin/env bash
# Tests for run-review.sh
# Run from any directory: bash ~/.claude/hooks/tests/run-review-test.sh
#
# Tests cover:
#   1. set -e propagation: transient Claude CLI failure must produce log output beyond bare exit_code
#   2. Chunked review log: reviewer output must appear in REVIEW_LOG when chunked path runs
#   3. Dead agent_exit check: agent errors in chunked mode must be skipped gracefully (not fatal)
#   4. Stderr hint: chunked review failure (blocking verdict) must emit workaround hint

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${SCRIPT_DIR}/../run-review.sh"
REVIEW_LOG="${HOME}/.claude/last-review-result.log"

PASS=0
FAIL=0

# --- Test helpers ---
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${desc}"
    ((PASS += 1))
  else
    echo "  FAIL: ${desc}"
    echo "        expected NOT to find: ${needle}"
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
    printf '#!/usr/bin/env bash\n# File %d\n' "$i" >"file${i}.sh"
    for j in $(seq 1 8); do
      echo "echo line_${j}_of_file_${i}" >>"file${i}.sh"
    done
    git add "file${i}.sh"
  done
  cd - >/dev/null
}

# Create mock claude binary with given exit code and stdout output
make_mock_claude() {
  local mock_dir="$1" exit_code="$2" output="$3"
  mkdir -p "${mock_dir}"
  cat >"${mock_dir}/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${output}"
exit ${exit_code}
EOF
  chmod +x "${mock_dir}/claude"
}

cleanup() {
  rm -rf "${TMPDIR_TEST}"
  # Restore review.maxLines if we changed it
  if [[ -d "${REPO_DIR}" ]]; then
    cd "${REPO_DIR}" 2>/dev/null && git config --unset review.maxLines 2>/dev/null || true
    cd - >/dev/null 2>/dev/null || true
  fi
}
trap cleanup EXIT

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

rm -f "${REVIEW_LOG}"

cd "${REPO_DIR}"
CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${REVIEW_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains agent error info (not just bare exit_code: 1)" \
  "agent error" \
  "${log_content}"

# Transient agent failure (both reviewers error) must not block the commit.
# Both produce VERDICT: FAIL (agent error: 1) with no SEVERITY: BLOCKING —
# they should be treated as non-blocking warnings, not genuine rejections.
exit_t1=0
cd "${REPO_DIR}"
CLAUDE_CLI="${MOCK1_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>/dev/null || exit_t1=$?
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

rm -f "${REVIEW_LOG}"

cd "${REPO_DIR}"
git config review.maxLines 10
CLAUDE_CLI="${MOCK2_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>/dev/null || true
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${REVIEW_LOG}" 2>/dev/null || echo "")"

assert_contains \
  "log contains CHUNKED REVIEW section header" \
  "CHUNKED REVIEW" \
  "${log_content}"

assert_contains \
  "log contains file review count (Reviewed: N/N files)" \
  "Reviewed:" \
  "${log_content}"

# =========================================================
# TEST 3: Dead agent_exit check — agent error in chunked mode is gracefully skipped
#
# When Claude CLI fails for a file chunk, the file should be SKIPPED (logged as
# skipped due to agent error) rather than counting as a blocking issue.
# Currently: agent_exit -eq 2 is dead code (invoke_agent returns 0 or 1, not 2),
# so errors fall through to verdict parsing as FAIL, not skipped.
# =========================================================
echo ""
echo "=== Test 3: Agent error in chunked mode is skipped, not fatal ==="

setup_repo
stage_large_change

MOCK3_DIR="${TMPDIR_TEST}/mock3"
make_mock_claude "${MOCK3_DIR}" 1 "" # Claude exits non-zero (transient failure)

rm -f "${REVIEW_LOG}"

exit_code_t3=0
cd "${REPO_DIR}"
git config review.maxLines 10
CLAUDE_CLI="${MOCK3_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>/dev/null || exit_code_t3=$?
git config --unset review.maxLines 2>/dev/null || true
cd - >/dev/null

log_content="$(cat "${REVIEW_LOG}" 2>/dev/null || echo "")"

assert_eq \
  "chunked review with transient agent errors does not block commit (exit 0)" \
  "0" \
  "${exit_code_t3}"

assert_contains \
  "log notes files were skipped due to agent error" \
  "skipped" \
  "${log_content}"

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

rm -f "${REVIEW_LOG}"

stderr_out=""
cd "${REPO_DIR}"
git config review.maxLines 10
stderr_out="$(CLAUDE_CLI="${MOCK4_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>&1 || true)"
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
cat >"${MOCK5_DIR}/claude" <<'MOCKEOF'
#!/usr/bin/env bash
sleep 5
echo "VERDICT: PASS"
echo "No blocking issues found."
MOCKEOF
chmod +x "${MOCK5_DIR}/claude"

rm -f "${REVIEW_LOG}"

cd "${REPO_DIR}"
git config review.timeout 1
CLAUDE_CLI="${MOCK5_DIR}/claude" bash "${SUBJECT}" < <(git diff --cached) 2>/dev/null || true
git config --unset review.timeout 2>/dev/null || true
cd - >/dev/null

log_content5="$(cat "${REVIEW_LOG}" 2>/dev/null || echo "")"

# If the config is honoured, the 1s timeout fires and the log records the timeout
assert_contains \
  "review.timeout=1 causes timeout to fire (config is read)" \
  "timeout" \
  "${log_content5}"

# =========================================================
# Summary
# =========================================================
echo ""
echo "======================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "======================================="

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
