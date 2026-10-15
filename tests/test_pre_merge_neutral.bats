#!/usr/bin/env bats
# Tests the NEUTRAL-conclusion gate in pre-merge-review.sh
# (smartwatermelon/claude-config#726).
#
# Bug: the gate blocked on NEUTRAL from ANY check. CodeQL default setup reports
# NEUTRAL ("3 configurations not found") on every Dependabot PR in
# smartwatermelon/personify, where CodeQL is not a required check, so the hook
# was stricter than branch protection and blocked every Dependabot merge.
#
# Decision (2026-10-15): NEUTRAL blocks only on a REQUIRED check. NEUTRAL on a
# non-required check is a warning and goes to the analysis as advisory. When
# the required set cannot be read, every NEUTRAL still blocks (fail closed,
# same rule as #687).
#
# The CodeQL rollup node below is the measured shape from personify#116.
#
# Run: bats tests/test_pre_merge_neutral.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/pre-merge-review.sh"

PR_BASE='"number":41,"title":"neutral","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","baseRefName":"main","url":"https://github.com/o/r/pull/41","author":{"login":"app/dependabot"}'

REQ_TWO='{"contexts":["validate","standards-check / run-standards-check"]}'
GREEN_REQUIRED='{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"standards-check / run-standards-check","status":"COMPLETED","conclusion":"SUCCESS"}'
CODEQL_NEUTRAL='{"__typename":"CheckRun","name":"CodeQL","status":"COMPLETED","conclusion":"NEUTRAL","detailsUrl":"https://github.com/o/r/runs/116661338732","workflowName":""}'

setup() {
  # BATS_TEST_TMPDIR is per-test and removed by bats, so no teardown is needed.
  MOCK_DIR="${BATS_TEST_TMPDIR}"
  export MOCK_DIR
  mkdir -p "${MOCK_DIR}/home/.claude/hooks"
  cat >"${MOCK_DIR}/home/.claude/hooks/merge-lock.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/home/.claude/hooks/merge-lock.sh"

  printf 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n' \
    >"${MOCK_DIR}/pr.diff"

  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
cat >"${MOCK_DIR}/prompt.txt"
echo "VERDICT: SAFE_TO_MERGE"
EOF
  chmod +x "${MOCK_DIR}/claude"
}

# Write the mock gh.
#   $1  statusCheckRollup JSON value
#   $2  body of the required_status_checks protection endpoint, or "404"/"403"
_mock_gh() {
  local rollup="$1" protection="$2"
  printf '{%s,"statusCheckRollup":%s}\n' "${PR_BASE}" "${rollup}" >"${MOCK_DIR}/pr.json"
  printf '%s\n' "${protection}" >"${MOCK_DIR}/protection.json"
  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  if [[ "\$*" == *"--comments"* ]]; then
    exit 0
  fi
  cat "${MOCK_DIR}/pr.json"
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  cat "${MOCK_DIR}/pr.diff"
  exit 0
fi
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then
  echo "o/r"
  exit 0
fi
if [[ "\$1" == "api" && "\$2" == *"/protection/required_status_checks" ]]; then
  case "\$(cat "${MOCK_DIR}/protection.json")" in
    404) echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
    403) echo 'gh: Resource not accessible by personal access token (HTTP 403)' >&2; exit 1 ;;
  esac
  cat "${MOCK_DIR}/protection.json"
  exit 0
fi
echo "[]"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"
}

_run_hook() {
  run env -u OP_SERVICE_ACCOUNT_TOKEN HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    CLAUDE_CLI="${MOCK_DIR}/claude" PRE_MERGE_APP_DISABLE=1 \
    bash "${SCRIPT}" pr merge 41 --squash --delete-branch
}

# The hook must stop at the NEUTRAL gate: exit 1, never reach the analysis.
_assert_blocked() {
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"Merge blocked - resolve NEUTRAL checks first"* ]]
  [[ ! -f "${MOCK_DIR}/prompt.txt" ]]
}

# Fail when $1 appears in $2. Not `! grep`: errexit ignores a negated command.
_absent_in_output() {
  if [[ "${output}" == *"$1"* ]]; then
    echo "unexpected text '$1' in output" >&2
    return 1
  fi
}

@test "non-required NEUTRAL (CodeQL on a Dependabot PR) -> warning, not blocked, advisory in prompt" {
  _mock_gh "[${GREEN_REQUIRED},${CODEQL_NEUTRAL}]" "${REQ_TWO}"
  _run_hook
  [[ "${status}" -eq 0 ]]
  _absent_in_output "Merge blocked - resolve NEUTRAL checks first"
  [[ "${output}" == *"NEUTRAL on non-required checks (advisory, not blocking)"* ]]
  [[ "${output}" == *"- CodeQL: NEUTRAL"* ]]
  [[ -f "${MOCK_DIR}/prompt.txt" ]]
  sed -n '/^=== Non-Required CI Checks/,/^=== Review Data/p' \
    "${MOCK_DIR}/prompt.txt" >"${MOCK_DIR}/nonrequired.txt"
  grep -q -- "- CodeQL: COMPLETED (NEUTRAL)" "${MOCK_DIR}/nonrequired.txt"
  grep -q "Advisory: NEUTRAL on non-required checks did not block this merge: CodeQL" \
    "${MOCK_DIR}/nonrequired.txt"
  grep -q "do not output a NON_BLOCKING_ISSUE block for it" "${MOCK_DIR}/nonrequired.txt"
}

@test "required NEUTRAL -> blocked" {
  _mock_gh '[{"__typename":"CheckRun","name":"validate","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"CheckRun","name":"standards-check / run-standards-check","status":"COMPLETED","conclusion":"SUCCESS"}]' "${REQ_TWO}"
  _run_hook
  _assert_blocked
  [[ "${output}" == *"- validate: NEUTRAL"* ]]
}

@test "required NEUTRAL beside a non-required NEUTRAL -> blocked, only the required one is blocking" {
  _mock_gh "[{\"__typename\":\"CheckRun\",\"name\":\"validate\",\"status\":\"COMPLETED\",\"conclusion\":\"NEUTRAL\"},${CODEQL_NEUTRAL}]" "${REQ_TWO}"
  _run_hook
  _assert_blocked
  [[ "${output}" == *"Required CI checks with NEUTRAL status"* ]]
  [[ "${output}" == *"- validate: NEUTRAL"* ]]
}

@test "required list unreadable (404) + NEUTRAL -> blocked (fail closed)" {
  _mock_gh "[${GREEN_REQUIRED},${CODEQL_NEUTRAL}]" 404
  _run_hook
  _assert_blocked
  [[ "${output}" == *"- CodeQL: NEUTRAL"* ]]
  [[ "${output}" == *"required set could not be read"* ]]
}

@test "required list unreadable (403) + NEUTRAL -> blocked (fail closed)" {
  _mock_gh "[${GREEN_REQUIRED},${CODEQL_NEUTRAL}]" 403
  _run_hook
  _assert_blocked
  [[ "${output}" == *"- CodeQL: NEUTRAL"* ]]
}

@test "blocked NEUTRAL hint does not claim a coverage threshold was missed" {
  _mock_gh "[${GREEN_REQUIRED},${CODEQL_NEUTRAL}]" 404
  _run_hook
  _assert_blocked
  _absent_in_output "Threshold not met"
  # The check run link is printed so the human can read what NEUTRAL meant.
  [[ "${output}" == *"https://github.com/o/r/runs/116661338732"* ]]
}

@test "control: Seer NEUTRAL with the required list unreadable -> still exempt, not blocked" {
  _mock_gh '[{"__typename":"CheckRun","name":"Seer Code Review","status":"COMPLETED","conclusion":"NEUTRAL"}]' 404
  _run_hook
  _absent_in_output "Merge blocked - resolve NEUTRAL checks first"
  [[ -f "${MOCK_DIR}/prompt.txt" ]]
}
