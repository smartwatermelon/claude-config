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
