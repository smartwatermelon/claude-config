#!/usr/bin/env bats
# Tests for ~/.claude/scripts/hook-block-api-merge.sh
#
# Verifies that the PreToolUse Bash hook blocks direct REST API calls to the
# GitHub PR merge endpoint. This closes the bypass gap where:
#   `gh api repos/.../pulls/NNN/merge --method PUT`
# circumvents the gh() wrapper (which only intercepts `gh pr merge`).
#
# Root cause documented in post-mortems:
#   - PR #813 incident: gh pr merge failed silently → workaround used gh api
#   - v1.11.0 incident: that pattern was reused, bypassing all quality gates
#
# Run: bats ~/.claude/tests/test_hook_block_api_merge.bats

HOOK="${HOME}/.claude/scripts/hook-block-api-merge.sh"

# Build a Claude Code PreToolUse JSON payload for a Bash tool call.
# Uses jq to properly escape special characters (quotes, backslashes, etc.)
# in the command string so the JSON is always valid.
_make_input() {
  local cmd="$1"
  jq -n --arg cmd "${cmd}" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

@test "blocks: gh api .../pulls/NNN/merge --method PUT (standard form)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/merge --method PUT')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh api /repos/.../pulls/NNN/merge (leading slash)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api /repos/nightowlstudiollc/kebab-tax/pulls/829/merge --method PUT --field merge_method=squash')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh api .../pulls/NNN/merge with quoted path" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api "repos/owner/repo/pulls/123/merge" --method PUT')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh api .../pulls/NNN/merge with no --method flag" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/42/merge')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh api .../pulls/NNN/merge chained after other commands" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'echo done && gh api repos/o/r/pulls/99/merge --method PUT')"
  [ "$status" -eq 2 ]
}

@test "allows: gh api .../pulls/NNN/comments (not merge endpoint)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/comments')"
  [ "$status" -eq 0 ]
}

@test "allows: gh api .../pulls/NNN/reviews (not merge endpoint)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/reviews')"
  [ "$status" -eq 0 ]
}

@test "allows: gh pr merge NNN (routed through gh() wrapper, not REST API)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh pr merge 813 --squash')"
  [ "$status" -eq 0 ]
}

@test "allows: gh pr view NNN (read-only gh command)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh pr view 813 --json state')"
  [ "$status" -eq 0 ]
}

@test "allows: gh api repos/.../git/refs/heads/branch --method DELETE (branch cleanup)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/git/refs/heads/my-branch --method DELETE')"
  [ "$status" -eq 0 ]
}

@test "block logs to blocked-commands.log" {
  local log_file="${HOME}/.claude/blocked-commands.log"
  local before_size=0
  [[ -f "${log_file}" ]] && before_size=$(wc -l <"${log_file}")

  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/merge --method PUT')"

  [ "$status" -eq 2 ]
  [[ -f "${log_file}" ]]
  local after_size
  after_size=$(wc -l <"${log_file}")
  [ "$after_size" -gt "$before_size" ]
}

@test "block output mentions forbidden endpoint and correct alternative" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/merge --method PUT')"

  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"gh pr merge"* ]]
}

@test "blocks: gh api graphql with mergePullRequest mutation (GraphQL bypass)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api graphql -f query=mutation { mergePullRequest(input: {pullRequestId: "PR_kwDO"}) { pullRequest { merged } } }')"

  [ "$status" -eq 2 ]
}

@test "allows: gh api graphql with non-merge query (PR data fetch)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api graphql -f query=query { repository(owner: "o") { pullRequest(number: 1) { title } } }')"

  [ "$status" -eq 0 ]
}

@test "allows: gh api .../pulls/NNN/merge_status (suffix boundary — not the merge trigger)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh api repos/owner/repo/pulls/813/merge_status')"

  [ "$status" -eq 0 ]
}

# ── Global-flag bypass tests ─────────────────────────────────────────────────
# Root cause: `gh -R owner/repo pr merge NNN` has -R as $1 in the shell, so the
# gh() wrapper's `$1 == "pr"` check is skipped. The hook must catch it here.

@test "blocks: gh -R owner/repo pr merge NNN (global flag bypass)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh -R nightowlstudiollc/kebab-tax pr merge 841 --squash --delete-branch')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh --repo owner/repo pr merge NNN (long flag, two-token form)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh --repo nightowlstudiollc/kebab-tax pr merge 841 --squash')"
  [ "$status" -eq 2 ]
}

@test "blocks: gh --repo=owner/repo pr merge NNN (long flag, embedded value form)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh --repo=nightowlstudiollc/kebab-tax pr merge 841 --squash')"
  [ "$status" -eq 2 ]
}

@test "blocks: echo x && gh -R owner/repo pr merge NNN (chained with &&)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'echo x && gh -R owner/repo pr merge 841')"
  [ "$status" -eq 2 ]
}

@test "blocks: false || gh -R owner/repo pr merge NNN (chained with ||)" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'false || gh -R owner/repo pr merge 841')"
  [ "$status" -eq 2 ]
}

@test "allows: gh pr merge NNN --squash (normal path, no global flags before subcommand)" {
  # Regression guard: normal gh pr merge must NOT be blocked by the new check.
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh pr merge 841 --squash')"
  [ "$status" -eq 0 ]
}

@test "allows: commit message text mentioning the bypass (not a shell command)" {
  # Regression: 'gh -R owner/repo pr merge' appearing inside a quoted git commit
  # message must not be blocked. The anchor requires 'gh' to start a line or
  # follow a shell operator, so text after '-' or '`' is not matched.
  local commit_cmd
  commit_cmd='git commit -m "fix: block - gh -R owner/repo pr merge bypass"'
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input "${commit_cmd}")"
  [ "$status" -eq 0 ]
}

@test "blocks global flag bypass output mentions BLOCKED and correct alternative" {
  run bash -c "printf '%s' \"\$(cat)\" | \"${HOOK}\"" <<<"$(_make_input 'gh -R owner/repo pr merge 841 --squash')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  [[ "$output" == *"gh pr merge"* ]]
}
