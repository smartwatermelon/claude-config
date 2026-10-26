#!/usr/bin/env bats
# Tests that pre-merge-review.sh fails CLOSED when CI status cannot be read
# (smartwatermelon/claude-config#687).
#
# Bug: on private repos every GH_TOKEN_* is a fine-grained PAT with no Checks
# permission. `gh pr view --json ...statusCheckRollup...` fails with the
# FORBIDDEN error below, the hook retries WITHOUT the rollup, and then reads
# the missing rollup as `[]`. With branch protection readable, that rendered
# "(none — no required status checks on this branch)" — false, the branch had
# a required check — and the placeholder matched no failure word, so the hook
# set ci_passed=true and put the false line into the analysis prompt under
# "these gate the merge".
#
# The stderr fixture is the measured gh output from 2026-10-12 against a
# private repo, not a paraphrase. gh omits unrequested keys from --json output
# (measured: `gh pr view --json number,title | jq keys` -> ["number","title"]),
# so the fallback PR JSON below carries no statusCheckRollup key at all.
#
# Run: bats tests/test_pre_merge_ci_read.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/pre-merge-review.sh"

FORBIDDEN_STDERR='GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup)'
PR_BASE='"number":31,"title":"ci read","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","baseRefName":"main","url":"https://github.com/o/r/pull/31","author":{"login":"someone"}'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  mkdir -p "${MOCK_DIR}/home/.claude/hooks"
  # The policy says lock and check passes, so the run reaches the code under test.
  cat >"${MOCK_DIR}/home/.claude/hooks/merge-lock.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "policy" ]] && printf 'lock\trule 1\t*\n'
exit 0
EOF
  chmod +x "${MOCK_DIR}/home/.claude/hooks/merge-lock.sh"

  # A code diff over DIFF_LINE_THRESHOLD lines, so build_targeted_diff takes
  # the smart path, where ci_passed decides whether files get truncated.
  {
    printf 'diff --git a/src/big.js b/src/big.js\n'
    printf 'index 1111111..2222222 100644\n--- a/src/big.js\n+++ b/src/big.js\n'
    printf '@@ -1,1 +1,1300 @@\n'
    local i
    for ((i = 1; i <= 1300; i += 1)); do
      printf '+const line%d = %d;\n' "${i}" "${i}"
    done
  } >"${MOCK_DIR}/pr.diff"

  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
cat >"${MOCK_DIR}/prompt.txt"
echo "VERDICT: SAFE_TO_MERGE"
EOF
  chmod +x "${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Write the mock gh.
#   $1  "forbidden" -> first pr view fails with the measured FORBIDDEN error,
#                      the retry returns PR JSON with no statusCheckRollup key
#       anything else -> used verbatim as the statusCheckRollup JSON value
#   $2  body of the required_status_checks protection endpoint, or "404"
_mock_gh() {
  local rollup="$1" protection="$2"
  printf '%s\n' "${FORBIDDEN_STDERR}" >"${MOCK_DIR}/forbidden.err"
  if [[ "${rollup}" == "forbidden" ]]; then
    printf '{%s}\n' "${PR_BASE}" >"${MOCK_DIR}/pr.json"
  else
    printf '{%s,"statusCheckRollup":%s}\n' "${PR_BASE}" "${rollup}" >"${MOCK_DIR}/pr.json"
  fi
  printf '%s\n' "${protection}" >"${MOCK_DIR}/protection.json"
  local mode=readable
  [[ "${rollup}" == "forbidden" ]] && mode=forbidden
  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  if [[ "\$*" == *"--comments"* ]]; then
    exit 0
  fi
  if [[ "${mode}" == "forbidden" &&"\$*" == *statusCheckRollup* ]]; then
    cat "${MOCK_DIR}/forbidden.err" >&2
    exit 1
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
  if [[ "\$(cat "${MOCK_DIR}/protection.json")" == "404" ]]; then
    echo 'gh: Branch not protected (HTTP 404)' >&2
    exit 1
  fi
  cat "${MOCK_DIR}/protection.json"
  exit 0
fi
echo "[]"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"
}

_run_hook() {
  # The App token path (tests/test_pre_merge_app_token.bats) is off here: these
  # cases test the default-credentials read, and must never reach 1Password.
  run env -u OP_SERVICE_ACCOUNT_TOKEN HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    CLAUDE_CLI="${MOCK_DIR}/claude" PRE_MERGE_APP_DISABLE=1 \
    bash "${SCRIPT}" pr merge 31 --squash --delete-branch
  [[ -f "${MOCK_DIR}/prompt.txt" ]] || {
    echo "hook never reached the analysis; output: ${output}" >&2
    return 1
  }
  # Only the Required CI Checks section. The fixed prompt template itself
  # mentions "CI status unreadable" in its rules, so grepping the whole
  # prompt would pass for the wrong reason.
  sed -n '/^=== Required CI Checks/,/^=== Non-Required CI Checks/p' \
    "${MOCK_DIR}/prompt.txt" >"${MOCK_DIR}/required.txt"
  [[ -s "${MOCK_DIR}/required.txt" ]]
}

# Fail when $1 appears in file $2. Not `! grep`: bash errexit ignores a
# negated command, so a `! grep` that is not a test's last line never fails it.
_absent() {
  if grep -qF -- "$1" "$2"; then
    echo "unexpected text '$1' in $2" >&2
    return 1
  fi
}

# Every fail-closed case must hold all of these.
_assert_not_passed() {
  [[ "${output}" != *"Required CI checks passed"* ]]
  _absent "no required status checks" "${MOCK_DIR}/required.txt"
  _absent "Status checks unavailable" "${MOCK_DIR}/required.txt"
  # Not truncated as "CI passed": the smart diff shows the file in full.
  grep -q "Files truncated (no comments, CI passed): 0" "${MOCK_DIR}/prompt.txt"
}

REQ_ONE='{"contexts":["claude-review / run-review"]}'
GREEN_ROLLUP='[{"__typename":"CheckRun","name":"claude-review / run-review","status":"COMPLETED","conclusion":"SUCCESS"}]'

@test "control: readable rollup with the required check green -> CI passed" {
  _mock_gh "${GREEN_ROLLUP}" "${REQ_ONE}"
  _run_hook
  [[ "${output}" == *"Required CI checks passed"* ]]
  grep -q "Files truncated (no comments, CI passed): 1" "${MOCK_DIR}/prompt.txt"
  grep -q -- "- claude-review / run-review: COMPLETED (SUCCESS)" "${MOCK_DIR}/required.txt"
}

@test "FORBIDDEN rollup read with a required check -> unreadable, not passed" {
  _mock_gh forbidden "${REQ_ONE}"
  _run_hook
  _assert_not_passed
  grep -q "CI status unreadable" "${MOCK_DIR}/required.txt"
  [[ "${output}" == *"CI status unreadable"* ]]
  # The prompt still names what is required, so the model knows what is unverified.
  grep -q "claude-review / run-review" "${MOCK_DIR}/required.txt"
}

@test "FORBIDDEN rollup read with protection unreadable -> unreadable, not passed" {
  _mock_gh forbidden 404
  _run_hook
  _assert_not_passed
  grep -q "CI status unreadable" "${MOCK_DIR}/required.txt"
  [[ "${output}" == *"CI status unreadable"* ]]
}

@test "empty rollup while a required check exists -> unreadable, not passed" {
  _mock_gh '[]' "${REQ_ONE}"
  _run_hook
  _assert_not_passed
  grep -q "CI status unreadable" "${MOCK_DIR}/required.txt"
  grep -q "claude-review / run-review" "${MOCK_DIR}/required.txt"
}

@test "empty rollup with protection unreadable ((none) placeholder) -> unreadable, not passed" {
  _mock_gh '[]' 404
  _run_hook
  _assert_not_passed
  grep -q "CI status unreadable" "${MOCK_DIR}/required.txt"
}

@test "required check missing from a non-empty rollup -> not passed, named as missing" {
  _mock_gh '[{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS"}]' "${REQ_ONE}"
  _run_hook
  _assert_not_passed
  grep -q -- "- claude-review / run-review: MISSING" "${MOCK_DIR}/required.txt"
}

@test "protection readable with zero required contexts -> said accurately, not passed" {
  _mock_gh "${GREEN_ROLLUP}" '{"contexts":[]}'
  _run_hook
  [[ "${output}" != *"Required CI checks passed"* ]]
  grep -q "Files truncated (no comments, CI passed): 0" "${MOCK_DIR}/prompt.txt"
  grep -q "branch protection requires no status checks" "${MOCK_DIR}/required.txt"
  _absent "CI status unreadable" "${MOCK_DIR}/required.txt"
}

@test "StatusContext ERROR on a required context -> not passed" {
  # The old failure-word grep had no ERROR, so a StatusContext in ERROR passed.
  _mock_gh '[{"__typename":"StatusContext","context":"claude-review / run-review","state":"ERROR"}]' "${REQ_ONE}"
  _run_hook
  _assert_not_passed
}

@test "SKIPPED required check counts as passing (GitHub treats skipped as successful)" {
  _mock_gh '[{"__typename":"CheckRun","name":"claude-review / run-review","status":"COMPLETED","conclusion":"SKIPPED"}]' "${REQ_ONE}"
  _run_hook
  [[ "${output}" == *"Required CI checks passed"* ]]
}
