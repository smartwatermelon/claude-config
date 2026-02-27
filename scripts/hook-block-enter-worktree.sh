#!/usr/bin/env bash
# Hook: Block the EnterWorktree built-in tool
#
# Purpose:
#   EnterWorktree is a Claude Code built-in tool that creates an isolated git
#   worktree. CC add-on skills (e.g. superpowers:using-git-worktrees) invoke
#   this tool for task isolation, which conflicts with the project workflow.
#
#   This hook fires via PreToolUse matcher "EnterWorktree" and unconditionally
#   blocks the tool. The Bash-level `git worktree` command is blocked separately
#   by hook-block-git-worktree.sh in the hook-block-all.sh chain.

set -euo pipefail

input=$(cat)
printf '%s BLOCKED ENTER_WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${input}" \
  >>"${HOME}/.claude/blocked-commands.log"
printf '🛑 BLOCKED: The EnterWorktree tool is forbidden.\n' >&2
printf '\n' >&2
printf 'Worktrees conflict with the project workflow. There is no valid use case for them here.\n' >&2
printf '\n' >&2
printf 'For task isolation, work directly on a feature branch instead:\n' >&2
printf '  git checkout -b claude/<description>\n' >&2
exit 2
