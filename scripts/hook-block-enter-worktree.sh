#!/usr/bin/env bash
# Hook: Gate the EnterWorktree built-in tool
#
# Purpose:
#   EnterWorktree is a Claude Code built-in tool that creates an isolated git
#   worktree. It is the tool-level counterpart to the Bash-level `git worktree`
#   creation gated by hook-block-git-worktree.sh.
#
#   Policy (see smartwatermelon/dotfiles#200, superseding the blanket ban):
#   worktree creation is ALLOWED, because subagent-driven execution is the
#   documented default in CLAUDE.md and a shared checkout is not isolation --
#   `git checkout -b` swaps the branch out from under a concurrent agent
#   mid-edit. Blocking this tool while permitting scoped Bash-level creation
#   would be incoherent: they are the same mechanism through different doors.
#
#   PATH SCOPING DOES NOT APPLY HERE, and that is not an oversight. The Bash
#   hook restricts creation to `.claude/worktrees/` because a raw git command
#   can target anywhere. EnterWorktree's tool_input carries only a `name`
#   (observed payload: {"tool_input":{"name":"my-worktree"}}) -- the caller
#   cannot choose a location, so there is no path to validate and no way for
#   this tool to escape the harness-chosen directory. What IS validated is the
#   name itself, which becomes a path component: it must be a plain slug, so it
#   cannot traverse out of that directory or inject shell/path metacharacters.
#
# Called by: settings.json PreToolUse matcher "EnterWorktree"

set -euo pipefail

input=$(cat)
# NOTE: the `$( )` command substitution strips trailing newlines, so a name of
# `good\n` reaches the regex as `good` and is accepted (harmlessly -- what gets
# used is the sanitized value). An embedded newline mid-string, e.g.
# `good\nEVIL`, survives and is correctly denied by the anchored regex below.
# A future refactor to `jq -j` or a `read -r`-based read would remove that
# stripping and change this behavior -- re-test the newline cases if you touch it.
name=$(printf '%s\n' "${input}" | jq -r '.tool_input.name // empty')

deny() {
  local reason="${1}"
  printf '%s BLOCKED ENTER_WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${input}" \
    >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: %s\n' "${reason}" >&2
  printf '\n' >&2
  printf 'Worktree creation is permitted (dotfiles#200), but the worktree name\n' >&2
  printf 'becomes a directory component, so it must be a plain slug:\n' >&2
  printf '  letters, digits, dot, underscore, hyphen; 1-100 characters\n' >&2
  printf '  no slashes, no "..", no leading dot or hyphen\n' >&2
  printf '\n' >&2
  printf 'Example: fix-gh-wrapper-issue-parsing\n' >&2
  exit 2
}

# A missing/empty name would let the harness fall back to a default we cannot
# inspect. Require it explicitly.
[[ -n "${name}" ]] || deny "EnterWorktree requires an explicit worktree name"

# Reject the traversal component outright, ahead of the charset check, so the
# failure message is specific rather than a generic charset complaint.
[[ "${name}" == ".." ]] && deny "EnterWorktree name '..' is forbidden (path traversal)"

# Allowlist the charset. Slashes are excluded, so the name cannot introduce a
# nested path; a leading dot or hyphen is excluded so the name cannot create a
# hidden directory or be mistaken for a flag by downstream tooling.
if [[ ! "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$ ]]; then
  deny "EnterWorktree name is not a valid slug (got: ${name})"
fi

exit 0
