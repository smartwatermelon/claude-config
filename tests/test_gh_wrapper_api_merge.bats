#!/usr/bin/env bats
# Tests for gh() wrapper extension — blocks gh api .../pulls/NNN/merge
#
# The Claude Code PreToolUse hook (hook-block-api-merge.sh) is the primary
# defense, but the gh() bash function wrapper provides a second layer:
# it also blocks `gh api .../pulls/NNN/merge` so the bypass is caught
# even when the hook isn't in play (e.g., direct terminal use).
#
# Root cause documented in post-mortems:
#   - PR #813: gh pr merge failed silently → gh api used as workaround
#   - v1.11.0: pattern reused → 9-second unauthorized production merge
#
# Run: bats ~/.claude/tests/test_gh_wrapper_api_merge.bats

FUNCTIONS_SH="${HOME}/.config/bash/functions.sh"

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock gh binary that just exits 0
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Build mock HOME with a review script that records calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  cat >"${MOCK_HOME}/.claude/hooks/pre-merge-review.sh" <<EOF
#!/usr/bin/env bash
echo "called" >"${MOCK_DIR}/review_called"
exit 0
EOF
  chmod +x "${MOCK_HOME}/.claude/hooks/pre-merge-review.sh"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Load gh() from functions.sh into the current shell with MOCK_HOME active.
_load_gh_fn() {
  export HOME="${MOCK_HOME}"
  local func_def
  func_def=$(sed -n '/^gh()/,/^export -f gh$/p' "${FUNCTIONS_SH}")
  eval "${func_def}"
}

@test "gh api .../pulls/NNN/merge is blocked by wrapper" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [ "$status" -ne 0 ]
}

@test "gh api .../pulls/NNN/merge block message mentions gh pr merge alternative" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [ "$status" -ne 0 ]
  [[ "$output" == *"gh pr merge"* ]]
}

@test "gh api .../pulls/NNN/merge does NOT call pre-merge-review.sh (wrapper blocks before reaching review)" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh api .../pulls/NNN/comments passes through (not the merge endpoint)" {
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/comments

  [ "$status" -eq 0 ]
}

@test "gh api repos/.../git/refs/heads/branch --method DELETE passes through (branch cleanup)" {
  _load_gh_fn

  run gh api repos/owner/repo/git/refs/heads/my-branch --method DELETE

  [ "$status" -eq 0 ]
}

@test "gh pr merge 123 still calls review script (not broken by api merge block)" {
  _load_gh_fn

  gh pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status still passes through (not broken by api merge block)" {
  _load_gh_fn

  run gh status

  [ "$status" -eq 0 ]
  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh api .../pulls/NNN/merge --help is still blocked (--help does not bypass merge block)" {
  # Regression guard: the --help early-return must not run before the API merge check.
  # gh api repos/.../pulls/NNN/merge --help should be blocked even when --help is present,
  # because the intent to use the merge endpoint is what matters.
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge --method PUT --help

  [ "$status" -ne 0 ]
}

@test "gh api graphql with mergePullRequest mutation is blocked" {
  # GraphQL merge bypass: gh api graphql -f query="mutation { mergePullRequest(...) }"
  # Same class of bypass as REST merge endpoint.
  _load_gh_fn

  run gh api graphql -f 'query=mutation { mergePullRequest(input: {pullRequestId: "PR_kwDO"}) { pullRequest { merged } } }'

  [ "$status" -ne 0 ]
}

@test "gh api graphql with non-merge query passes through" {
  # Legitimate GraphQL queries (e.g., fetching PR data) must not be blocked.
  _load_gh_fn

  run gh api graphql -f 'query=query { repository(owner: "o", name: "r") { pullRequest(number: 1) { title } } }'

  [ "$status" -eq 0 ]
}

@test "gh api .../pulls/NNN/merge_status does NOT match (suffix boundary)" {
  # Hypothetical endpoint: pulls/NNN/merge_status is NOT the merge trigger.
  # The regex must not have false positives on suffixed paths.
  _load_gh_fn

  run gh api repos/owner/repo/pulls/813/merge_status

  [ "$status" -eq 0 ]
}
