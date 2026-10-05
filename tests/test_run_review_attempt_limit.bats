#!/usr/bin/env bats
# Tests for the commit-review attempt limit in run-review.sh (claude-config#646).
#
# Root cause: an agent retried a blocked commit about 8 times. Every retry
# re-ran the full review and got the same FAIL message, with no instruction
# to stop. The hook now counts consecutive blocked commit reviews per branch
# and, at review.maxAttempts, refuses without running a reviewer.
#
# Run: bats tests/test_run_review_attempt_limit.bats

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
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "init"

  GIT_DIR_ABS="$(git -C "${TMPDIR_TEST}" rev-parse --absolute-git-dir)"
  export GIT_DIR_ABS
  export EXPECTED_LOG="${GIT_DIR_ABS}/last-review-result.log"
  export ATTEMPTS_DIR="${GIT_DIR_ABS}/review-attempts"

  # Mock claude CLI. MOCK_VERDICT picks the answer. Each reviewer (--agent)
  # call is counted, so a test can prove a refused attempt ran no reviewer.
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export CALL_LOG="${MOCK_DIR}/calls"
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "mock 0.0.0"; exit 0; }
cat > /dev/null
[[ " $* " == *" --agent "* ]] && echo call >>"${CALL_LOG}"
if [[ "${MOCK_VERDICT:-PASS}" == "FAIL" ]]; then
  jq -n '{type:"result",subtype:"success",is_error:false,
          result:"VERDICT: FAIL\nSEVERITY: BLOCKING\nmock blocking finding",
          structured_output:{verdict:"FAIL",blocking:true,findings:[]}}'
else
  jq -n '{type:"result",subtype:"success",is_error:false,
          result:"VERDICT: PASS\nNo blocking issues found.",
          structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
fi
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  # Sandbox HOME; leaves adversarial-reviewer uninstalled.
  export HOME="${MOCK_DIR}/home"
  mkdir -p "${HOME}/.claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# $1 varies the diff, so no attempt hits the review cache.
run_review() {
  cd "${TMPDIR_TEST}" || exit
  printf 'diff --git a/foo.js b/foo.js\nindex 0000000..1234567 100644\n--- a/foo.js\n+++ b/foo.js\n@@ -0,0 +1 @@\n+const x = %s;\n' "${1:-1}" \
    | REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
      bash "${SCRIPT}"
}

count_file() {
  cat "${ATTEMPTS_DIR}/$1"
}

calls() {
  if [[ -f "${CALL_LOG}" ]]; then wc -l <"${CALL_LOG}" | tr -d ' '; else echo 0; fi
}

@test "each blocked review increments the branch counter" {
  MOCK_VERDICT=FAIL run run_review 1
  [ "${status}" -ne 0 ]
  [ "$(count_file test-branch)" -eq 1 ]
  # Proves the mock counts reviewer calls, so the refusal test's 0 means something.
  [ "$(calls)" -ge 1 ]
  MOCK_VERDICT=FAIL run run_review 2
  [ "${status}" -ne 0 ]
  [ "$(count_file test-branch)" -eq 2 ]
  [[ "${output}" != *"STOP:"* ]]
}

@test "the Nth blocked review still blocks and prints the stop message" {
  local i
  for i in 1 2 3; do
    MOCK_VERDICT=FAIL run run_review "${i}"
    [ "${status}" -ne 0 ]
  done
  [ "$(count_file test-branch)" -eq 3 ]
  [[ "${output}" == *"STOP: 3 consecutive blocked commit reviews"* ]]
  [[ "${output}" == *"do NOT retry"* ]]
  [[ "${output}" == *"Human reset: rm '${ATTEMPTS_DIR}/test-branch'"* ]]
}

@test "past the limit the hook refuses without running a reviewer, even on a clean diff" {
  mkdir -p "${ATTEMPTS_DIR}"
  echo 3 >"${ATTEMPTS_DIR}/test-branch"
  MOCK_VERDICT=PASS run run_review 9
  [ "${status}" -ne 0 ]
  [ "$(calls)" -eq 0 ]
  [[ "${output}" == *"refused without review"* ]]
  # A refusal does not bump the count, and does not reset it.
  [ "$(count_file test-branch)" -eq 3 ]
  grep -q '^blocked: attempt limit reached (3 of 3)$' "${EXPECTED_LOG}"
}

@test "a passing review resets the counter" {
  MOCK_VERDICT=FAIL run run_review 1
  MOCK_VERDICT=FAIL run run_review 2
  [ "$(count_file test-branch)" -eq 2 ]
  MOCK_VERDICT=PASS run run_review 3
  [ "${status}" -eq 0 ]
  [ ! -e "${ATTEMPTS_DIR}/test-branch" ]
}

@test "each branch has its own counter" {
  MOCK_VERDICT=FAIL run run_review 1
  MOCK_VERDICT=FAIL run run_review 2
  MOCK_VERDICT=FAIL run run_review 3
  git -C "${TMPDIR_TEST}" checkout -q -b feat/other
  MOCK_VERDICT=FAIL run run_review 4
  [ "${status}" -ne 0 ]
  [[ "${output}" != *"refused without review"* ]]
  [[ "${output}" != *"STOP:"* ]]
  # Slashes in the branch name are flattened into one filename.
  [ "$(count_file feat_other)" -eq 1 ]
  [ "$(count_file test-branch)" -eq 3 ]
}

@test "review.maxAttempts sets the limit" {
  git -C "${TMPDIR_TEST}" config review.maxAttempts 1
  MOCK_VERDICT=FAIL run run_review 1
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"STOP: 1 consecutive"*"(limit: 1)"* ]]
  MOCK_VERDICT=PASS run run_review 2
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"refused without review"* ]]
}

@test "a non-positive review.maxAttempts falls back to 3" {
  git -C "${TMPDIR_TEST}" config review.maxAttempts 0
  MOCK_VERDICT=PASS run run_review 1
  [ "${status}" -eq 0 ]
  MOCK_VERDICT=FAIL run run_review 2
  [[ "${output}" != *"STOP:"* ]]
}

@test "the chunked path counts a blocked review too" {
  # The #646 loop ran on the chunked path (diff above review.maxLines).
  # That path reviews the staged index, so stage a real file.
  git -C "${TMPDIR_TEST}" config review.maxLines 3
  git -C "${TMPDIR_TEST}" config review.chunkSize 30
  printf 'a=1\nb=2\nc=3\nd=4\n' >"${TMPDIR_TEST}/big.sh"
  git -C "${TMPDIR_TEST}" add big.sh
  cd "${TMPDIR_TEST}" || exit
  MOCK_VERDICT=FAIL run bash -c 'git diff --cached | bash "$1"' _ "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"chunked"* ]]
  [ "$(count_file test-branch)" -eq 1 ]
}
