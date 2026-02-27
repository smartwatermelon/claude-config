#!/usr/bin/env bash
# Hook: Block git worktree commands
#
# Purpose:
#   git worktree creates and manages multiple working trees from a single repo.
#   CC add-on skills occasionally attempt to use worktrees for task isolation,
#   but this conflicts with the project workflow and causes problems.
#
#   Both the Bash-level `git worktree` command and the EnterWorktree built-in
#   tool are blocked. This script handles the Bash layer.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Match: git [optional-flags] worktree [subcommand]
# Requires `git` to appear as a command (at start of string or after shell operators &&, ||, ;, |).
# Handles interposed flags: git -C /path worktree add, git --no-pager worktree list, etc.
# The group (-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)* matches zero or more
# flag groups before `worktree`. Each group is a token starting with `-`, optionally followed by
# a non-flag value token. This prevents matching subcommands like `grep` (which don't start with
# `-`), so `git grep worktree` is NOT blocked.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*worktree([[:space:]]|$)'; then
  printf '%s BLOCKED GIT WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" \
    >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: git worktree commands are forbidden.\n' >&2
  printf '\n' >&2
  printf 'Worktrees conflict with the project workflow. There is no valid use case for them here.\n' >&2
  printf '\n' >&2
  printf 'For task isolation, work directly on a feature branch instead:\n' >&2
  printf '  git checkout -b claude/<description>\n' >&2
  exit 2
fi
