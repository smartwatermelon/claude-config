#!/usr/bin/env bats
# Tests that run-review.sh keeps a copy of the review log when a review blocks.
#
# Root cause (claude-config#455, dev-env#124): last-review-result.log is
# truncated at the start of every run, so the evidence for a blocked attempt
# was overwritten by the retry that followed it.
#
# Run: bats ~/.claude/tests/test_run_review_blocked_log.bats

# Resolve the script under test relative to THIS test file, so a worktree
# exercises its own copy rather than main's (see test_run_review_identity.bats).
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

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"
  export BLOCKED_DIR="${TMPDIR_TEST}/.git/review-blocked"

  # Mock claude CLI. MOCK_VERDICT picks the answer, so one mock covers both cases.
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { echo "mock 0.0.0"; exit 0; }
cat > /dev/null
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

  # Sandbox HOME: keeps the real global log pointer untouched, and leaves the
  # adversarial-reviewer uninstalled so only the mocked code-reviewer decides.
  export HOME="${MOCK_DIR}/home"
  mkdir -p "${HOME}/.claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

run_review() {
  cd "${TMPDIR_TEST}" || exit
  printf 'diff --git a/foo.js b/foo.js\nindex 0000000..1234567 100644\n--- a/foo.js\n+++ b/foo.js\n@@ -0,0 +1 @@\n+const x = 1;\n' \
    | REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
      bash "${SCRIPT}"
}

@test "a blocked review keeps a copy of its log in review-blocked/" {
  MOCK_VERDICT=FAIL run run_review
  [ "${status}" -ne 0 ]
  local copies=("${BLOCKED_DIR}"/*-commit.log)
  [ -f "${copies[0]}" ]
  [ "${#copies[@]}" -eq 1 ]
  # The copy is the complete log: reviewer output and the final exit code.
  grep -q "mock blocking finding" "${copies[0]}"
  grep -q "^exit_code: 1$" "${copies[0]}"
}

@test "a passing review keeps no copy" {
  MOCK_VERDICT=PASS run run_review
  [ "${status}" -eq 0 ]
  [ ! -e "${BLOCKED_DIR}" ]
  # The pass path runs the exit handler directly; it must still log once.
  [ "$(grep -c '^exit_code: 0$' "${EXPECTED_LOG}")" -eq 1 ]
}

@test "review-blocked/ keeps only the newest 20 copies" {
  mkdir -p "${BLOCKED_DIR}"
  local i
  for i in $(seq -w 1 25); do
    touch "${BLOCKED_DIR}/20200101T0000${i}Z-commit.log"
  done
  MOCK_VERDICT=FAIL run run_review
  [ "${status}" -ne 0 ]
  local copies=("${BLOCKED_DIR}"/*.log)
  [ "${#copies[@]}" -eq 20 ]
  # The oldest seeds went first; the new copy survived.
  [ ! -e "${BLOCKED_DIR}/20200101T000001Z-commit.log" ]
  grep -q "mock blocking finding" "${copies[19]}"
}
