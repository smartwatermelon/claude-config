#!/usr/bin/env bats
# Tests for the chunked (medium-diff) path of hooks/run-review.sh:
# perform_chunked_review, which runs when a commit-mode diff is larger than
# review.maxLines but not larger than review.skipThreshold.
#
# Two false passes lived here:
#
#   claude-config#451 — a file whose diff was larger than review.chunkSize was
#     skipped, and the run still printed "Chunked review passed". On a large
#     diff the big new file is the one most likely to be skipped, so the
#     review read the docs and passed the code unread.
#   claude-config#558 — the chunked path only ever called code-reviewer.
#     adversarial-reviewer never ran, and nothing in the output or the review
#     log said so.
#
# Fixtures are kept tiny by lowering maxLines/chunkSize in the temp repo.
#
# Run: bats tests/test_run_review_chunked.bats

# Resolve the script under test relative to THIS test file, not via
# ${HOME}/.claude/hooks, so a worktree tests its own copy.
SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  touch "${TMPDIR_TEST}/init.txt"
  git -C "${TMPDIR_TEST}" add init.txt
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  # Small thresholds so a ~60-line diff lands in the chunked band.
  git -C "${TMPDIR_TEST}" config review.maxLines 50
  git -C "${TMPDIR_TEST}" config review.chunkSize 30

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR

  # Fake HOME: run-review.sh decides whether adversarial-reviewer is installed
  # by looking under ${HOME}/.claude/plugins/marketplaces, and writes a global
  # log pointer under ${HOME}/.claude. Both must be deterministic and must not
  # touch the real home directory.
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # Mock claude CLI. Records every --agent it is asked to run, one per line
  # (append-only, so parallel invocations do not clobber each other). Returns
  # PASS unless ${MOCK_DIR}/fail-<agent> exists, in which case that agent
  # returns a BLOCKING FAIL, or ${MOCK_DIR}/error-<agent> exists, in which
  # case the CLI exits 1 with no output (an agent error).
  #
  # The chunked-path arbiter (#647) is told apart by its argv, not its agent
  # name: it runs as adversarial-reviewer too, so fail-adversarial-reviewer
  # must not also fail it. A call carrying --allowedTools is the arbiter; it
  # is recorded as "arbiter:<agent>" and answers PASS unless
  # ${MOCK_DIR}/arbiter-fail (FAIL), arbiter-empty (exit 0, no output) or
  # arbiter-error (exit 1) exists. Every call's argv is appended to
  # ${ARGV_RECORD} as one line, each argument in brackets, so [--tools][]
  # is distinguishable from [--tools][Read,Grep,Glob].
  export AGENT_RECORD="${MOCK_DIR}/agents-invoked"
  export ARGV_RECORD="${MOCK_DIR}/argv-invoked"
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
agent=""
prev=""
is_arbiter=false
argv_line=""
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "\$prev" == "--agent" ]] && agent="\$a"
  [[ "\$a" == "--allowedTools" ]] && is_arbiter=true
  argv_line="\${argv_line}[\$a]"
  prev="\$a"
done
printf '%s\n' "\${argv_line}" >>"${ARGV_RECORD}"
cat >/dev/null
if [[ "\${is_arbiter}" == true ]]; then
  printf 'arbiter:%s\n' "\${agent}" >>"${AGENT_RECORD}"
  [[ -f "${MOCK_DIR}/arbiter-error" ]] && exit 1
  [[ -f "${MOCK_DIR}/arbiter-empty" ]] && exit 0
  if [[ -f "${MOCK_DIR}/arbiter-fail" ]]; then
    jq -n '{type:"result",subtype:"success",is_error:false,
      result:"VERDICT: FAIL\nThe finding holds.\nISSUE: upheld\nSEVERITY: BLOCKING\nLOCATION: a.sh:1\nDETAILS: mock",
      structured_output:{verdict:"FAIL",blocking:true,findings:[{severity:"BLOCKING",location:"a.sh:1",issue:"upheld"}]}}'
  else
    jq -n '{type:"result",subtype:"success",is_error:false,
      result:"VERDICT: PASS\nRead a.sh; the claim does not match the code.",
      structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
  fi
  exit 0
fi
printf '%s\n' "\${agent}" >>"${AGENT_RECORD}"
[[ -f "${MOCK_DIR}/error-\${agent}" ]] && exit 1
if [[ -f "${MOCK_DIR}/fail-\${agent}" ]]; then
  # A non-empty fail-<agent> file overrides the finding: line 1 ISSUE,
  # line 2 LOCATION, line 3 DETAILS.
  issue="mock blocking issue"; loc="x:1"; details="mock"
  if [[ -s "${MOCK_DIR}/fail-\${agent}" ]]; then
    { IFS= read -r issue; IFS= read -r loc; IFS= read -r details; } <"${MOCK_DIR}/fail-\${agent}"
  fi
  jq -n --arg i "\${issue}" --arg l "\${loc}" --arg d "\${details}" \
    '{type:"result",subtype:"success",is_error:false,
      result:("VERDICT: FAIL\nISSUE: " + \$i + "\nSEVERITY: BLOCKING\nLOCATION: " + \$l + "\nDETAILS: " + \$d),
      structured_output:{verdict:"FAIL",blocking:true,
        findings:[{severity:"BLOCKING",location:\$l,issue:\$i}]}}'
else
  jq -n '{type:"result",subtype:"success",is_error:false,
          result:"VERDICT: PASS\nNo blocking issues found.",
          structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
fi
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Write a shell file of N lines into the temp repo.
_write_file() {
  local path="$1" lines="$2" i
  : >"${TMPDIR_TEST}/${path}"
  for ((i = 0; i < lines; i += 1)); do
    printf 'echo "line %d"\n' "${i}" >>"${TMPDIR_TEST}/${path}"
  done
}

# run-review.sh reads the staged index of its own working directory, so it is
# launched from inside the temp repo, in a subshell so the directory change
# cannot leak. GIT_CONFIG_GLOBAL=/dev/null keeps the developer's own review.*
# keys out of the routing decision.
_run_review() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" "$@"
  )
}

# --- #451: a skipped file must never produce a pass --------------------------

@test "#451: a file larger than chunkSize blocks the commit instead of passing unread" {
  _write_file "big.sh" 40   # ~45 diff lines > chunkSize 30
  _write_file "small.sh" 20 # ~25 diff lines, reviewed
  git -C "${TMPDIR_TEST}" add big.sh small.sh

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" != *"Chunked review passed"* ]]
  # The unreviewed file is named, with the remedy.
  [[ "$output" == *"big.sh"* ]]
  [[ "$output" == *"review.chunkSize"* ]]
  grep -q 'unreviewed: big.sh' "${EXPECTED_LOG}"
  grep -q 'chunked: INCOMPLETE' "${EXPECTED_LOG}"
}

@test "#451: raising chunkSize past the largest file lets the same diff pass" {
  _write_file "big.sh" 40
  _write_file "small.sh" 20
  git -C "${TMPDIR_TEST}" add big.sh small.sh
  git -C "${TMPDIR_TEST}" config review.chunkSize 100

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" == *"Chunked review passed"* ]]
  ! grep -q 'unreviewed:' "${EXPECTED_LOG}"
}

@test "#451: a per-file agent error blocks and names the file" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  # code-reviewer errors on every file; adversarial passes. Previously the
  # 0/N case blocked (#200) but any partial case passed; now all do.
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == "--version" ]] && { echo mock; exit 0; }; done
input=\$(cat)
if [[ "\$input" == *"Reviewing file: b.sh"* ]]; then exit 1; fi
jq -n '{type:"result",subtype:"success",is_error:false,
        result:"VERDICT: PASS",structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" != *"Chunked review passed"* ]]
  grep -q 'unreviewed: b.sh (agent error or timeout)' "${EXPECTED_LOG}"
  ! grep -q 'unreviewed: a.sh' "${EXPECTED_LOG}"
}

@test "#451: the skipThreshold block message also names review.chunkSize" {
  git -C "${TMPDIR_TEST}" config review.skipThreshold 60
  _write_file "big.sh" 80
  git -C "${TMPDIR_TEST}" add big.sh

  run _run_review
  [ "$status" -ne 0 ]
  [[ "$output" == *"review.skipThreshold"* ]]
  [[ "$output" == *"review.chunkSize"* ]]
}

# --- #558: adversarial-reviewer must run (or say it did not) -----------------

@test "#558: chunked review runs adversarial-reviewer and logs its verdict" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh

  run _run_review
  [ "$status" -eq 0 ]
  grep -qx 'adversarial-reviewer' "${AGENT_RECORD}"
  # Exactly one adversarial pass over the whole diff, not one per file.
  [ "$(grep -cx 'adversarial-reviewer' "${AGENT_RECORD}")" -eq 1 ]
  grep -q '^adversarial-reviewer: PASS' "${EXPECTED_LOG}"
  grep -q '^code-reviewer: PASS' "${EXPECTED_LOG}"
  [[ "$output" == *"code-reviewer + adversarial-reviewer"* ]]
}

@test "#558: a BLOCKING adversarial finding fails a chunked commit" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  touch "${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^adversarial-reviewer: FAIL' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer found issues"* ]]
}

@test "#558: when adversarial-reviewer is not installed, the skip is loud" {
  rm -rf "${FAKE_HOME}/.claude/plugins"
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh

  run _run_review
  [ "$status" -eq 0 ]
  ! grep -qx 'adversarial-reviewer' "${AGENT_RECORD}" || false
  grep -q '^adversarial-reviewer: skipped (agent not installed)' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer"*"not"* ]]
}

@test "#558: an adversarial-reviewer error is non-blocking but named in output and log" {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
  touch "${MOCK_DIR}/error-adversarial-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  grep -q '^adversarial-reviewer: skipped (timeout or agent error)' "${EXPECTED_LOG}"
  [[ "$output" == *"adversarial-reviewer timed out or errored - it did NOT review this commit"* ]]
  [[ "$output" == *"code-reviewer only"* ]]
}

# --- #646: out-of-diff findings are downgraded on the chunked path too -------
#
# The single-pass path runs downgrade_unverifiable_findings; the chunked path
# exited before reaching it, so a BLOCKING finding whose LOCATION names a file
# the reviewer was never shown blocked a large commit and not a small one.
# ghost.sh is in no fixture diff, and its name contains no fixture basename.

# The per-file agent name run-review.sh uses when review.codeReviewerAgent is
# unset; the mock keys its fail-<agent> file on it.
CODE_REVIEWER="comprehensive-review:comprehensive-review-code-reviewer"

_stage_three_files() {
  _write_file "a.sh" 20
  _write_file "b.sh" 20
  _write_file "c.sh" 20
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
}

@test "#646: a per-file BLOCKING finding at a path outside the diff is downgraded" {
  _stage_three_files
  printf '%s\n' "off-by-one in the loop bound" "ghost.sh:1" "the loop runs one extra time" \
    >"${MOCK_DIR}/fail-${CODE_REVIEWER}"

  run _run_review
  [ "$status" -eq 0 ]
  grep -q '^downgraded: LOCATION names no file in the reviewed diff (#488): ghost.sh:1' "${EXPECTED_LOG}"
  # One downgrade per file: each per-file reviewer reported it.
  [ "$(grep -c "^downgraded:" "${EXPECTED_LOG}")" -eq 3 ]
}

@test "#646: an adversarial BLOCKING finding at a path outside the diff is downgraded" {
  _stage_three_files
  printf '%s\n' "off-by-one in the loop bound" "ghost.sh:1" "the loop runs one extra time" \
    >"${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -eq 0 ]
  grep -q '^downgraded: LOCATION names no file in the reviewed diff (#488): ghost.sh:1' "${EXPECTED_LOG}"
  ! grep -q '^adversarial-reviewer: FAIL' "${EXPECTED_LOG}"
}

@test "#646: a security finding outside the diff still blocks (same exemption as single-pass)" {
  _stage_three_files
  # The adversarial pass passes, so the #647 arbiter runs; uphold the block
  # so this test sees only the downgrade decision.
  touch "${MOCK_DIR}/arbiter-fail"
  printf '%s\n' "hardcoded secret in config" "ghost.sh:1" "a credential is committed in plain text" \
    >"${MOCK_DIR}/fail-${CODE_REVIEWER}"

  run _run_review
  [ "$status" -ne 0 ]
  ! grep -q '^downgraded:' "${EXPECTED_LOG}"
}

@test "#646: a per-file BLOCKING finding at a path inside the diff still blocks" {
  _stage_three_files
  # The adversarial pass passes, so the #647 arbiter runs; uphold the block
  # so this test sees only the downgrade decision.
  touch "${MOCK_DIR}/arbiter-fail"
  printf '%s\n' "off-by-one in the loop bound" "a.sh:1" "the loop runs one extra time" \
    >"${MOCK_DIR}/fail-${CODE_REVIEWER}"

  run _run_review
  [ "$status" -ne 0 ]
  # The mock gives every per-file reviewer the same a.sh finding. a.sh's own
  # reviewer saw a.sh, so its finding blocks. The b.sh and c.sh reviewers did
  # not, so theirs are downgraded: the check is scoped to what each one saw.
  [ "$(grep -c "^downgraded:" "${EXPECTED_LOG}")" -eq 2 ]
  [[ "$output" == *"Blocking issues: 1"* ]]
}

@test "#646: an adversarial BLOCKING finding at a path inside the diff still blocks" {
  _stage_three_files
  printf '%s\n' "off-by-one in the loop bound" "c.sh:1" "the loop runs one extra time" \
    >"${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  ! grep -q '^downgraded:' "${EXPECTED_LOG}" || false
  grep -q '^adversarial-reviewer: FAIL' "${EXPECTED_LOG}"
}

# --- #647: an arbiter with read-only tools rules on per-file blocks -----------
#
# Per-file reviewers see one file's diff and no tools, and on 2026-09-30 they
# blocked a 2,162-line commit on claims the code contradicted while the
# whole-diff adversarial pass passed it. The single-pass path arbitrates that
# disagreement; the chunked path let the block stand. The arbiter here can
# Read/Grep/Glob, so it checks the claim against the file.

# One blocking per-file finding, on a.sh. b.sh's and c.sh's reviewers report
# the same a.sh location, which #646 downgrades, so exactly a.sh blocks.
_stage_one_blocking_file() {
  _stage_three_files
  printf '%s\n' "arguments reversed" "a.sh:1" "the call swaps its arguments" \
    >"${MOCK_DIR}/fail-${CODE_REVIEWER}"
}

@test "#647: per-file BLOCKING + adversarial PASS + arbiter PASS lets the commit through" {
  _stage_one_blocking_file

  run _run_review
  [ "$status" -eq 0 ]
  [ "$(grep -cx 'arbiter:adversarial-reviewer' "${AGENT_RECORD}")" -eq 1 ]
  grep -q '^arbiter: PASS (a.sh)' "${EXPECTED_LOG}"
  grep -q '^=== ARBITER: a.sh ===' "${EXPECTED_LOG}"
  # The original block stays on record, as on the single-pass path.
  grep -q '^code-reviewer: FAIL' "${EXPECTED_LOG}"
  [[ "$output" == *"Cleared by arbiter: 1/1"* ]]
  # The disagreement is recorded locally.
  grep -q '^arbiter_verdict: PASS' "${TMPDIR_TEST}/.git/reviewer-disagreements.log"
}

@test "#647: arbiter FAIL keeps the per-file block" {
  _stage_one_blocking_file
  touch "${MOCK_DIR}/arbiter-fail"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^arbiter: FAIL (a.sh)' "${EXPECTED_LOG}"
  [[ "$output" != *"Chunked review passed"* ]]
}

@test "#647: arbiter empty output fails closed" {
  _stage_one_blocking_file
  touch "${MOCK_DIR}/arbiter-empty"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^arbiter: FAIL (a.sh)' "${EXPECTED_LOG}"
}

@test "#647: arbiter agent error fails closed" {
  _stage_one_blocking_file
  touch "${MOCK_DIR}/arbiter-error"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^arbiter: FAIL (a.sh)' "${EXPECTED_LOG}"
}

@test "#647: a blocking adversarial FAIL means no arbiter call" {
  _stage_one_blocking_file
  printf '%s\n' "race in the loop" "c.sh:1" "the loop races" \
    >"${MOCK_DIR}/fail-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  ! grep -q '^arbiter:' "${AGENT_RECORD}" || false
  ! grep -q '^arbiter:' "${EXPECTED_LOG}"
}

@test "#647: an incomplete adversarial pass means no arbiter call" {
  _stage_one_blocking_file
  touch "${MOCK_DIR}/error-adversarial-reviewer"

  run _run_review
  [ "$status" -ne 0 ]
  ! grep -q '^arbiter:' "${AGENT_RECORD}" || false
  grep -q '^adversarial-reviewer: skipped (timeout or agent error)' "${EXPECTED_LOG}"
}

@test "#647: only the arbiter gets read-only tools; reviewers keep --tools \"\"" {
  _stage_one_blocking_file

  run _run_review
  [ "$status" -eq 0 ]
  local arbiter_argv reviewer_argv
  arbiter_argv=$(grep -F '[--allowedTools]' "${ARGV_RECORD}")
  [ "$(grep -cF '[--allowedTools]' "${ARGV_RECORD}")" -eq 1 ]
  [[ "${arbiter_argv}" == *"[--allowedTools][Read,Grep,Glob]"* ]]
  [[ "${arbiter_argv}" == *"[--tools][Read,Grep,Glob]"* ]]
  [[ "${arbiter_argv}" == *"[--strict-mcp-config]"* ]]
  [[ "${arbiter_argv}" != *"[--tools][]"* ]]
  # Three per-file reviewers and one adversarial pass, all with no tools.
  # Only --agent calls count: the model-alias probe also calls the CLI.
  reviewer_argv=$(grep -F '[--agent]' "${ARGV_RECORD}" | grep -vF '[--allowedTools]')
  [ "$(grep -c . <<<"${reviewer_argv}")" -eq 4 ]
  [ "$(grep -cF '[--tools][]' <<<"${reviewer_argv}")" -eq 4 ]
  [ "$(grep -cF "[--agent][${CODE_REVIEWER}]" <<<"${reviewer_argv}")" -eq 3 ]
  [ "$(grep -cF '[--agent][adversarial-reviewer]' <<<"${reviewer_argv}")" -eq 1 ]
}

@test "#647: an unreviewed file still blocks when the arbiter clears the rest" {
  _write_file "big.sh" 40 # > chunkSize 30: not reviewed
  _write_file "a.sh" 20
  git -C "${TMPDIR_TEST}" add big.sh a.sh
  printf '%s\n' "arguments reversed" "a.sh:1" "the call swaps its arguments" \
    >"${MOCK_DIR}/fail-${CODE_REVIEWER}"

  run _run_review
  [ "$status" -ne 0 ]
  grep -q '^arbiter: PASS (a.sh)' "${EXPECTED_LOG}"
  grep -q 'unreviewed: big.sh' "${EXPECTED_LOG}"
  grep -q 'chunked: INCOMPLETE' "${EXPECTED_LOG}"
  # The unreviewed file was not sent to the arbiter.
  [ "$(grep -cx 'arbiter:adversarial-reviewer' "${AGENT_RECORD}")" -eq 1 ]
}
