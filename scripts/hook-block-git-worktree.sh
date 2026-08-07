#!/usr/bin/env bash
# Hook: Block mutating git worktree subcommands
#
# Purpose:
#   git worktree creates and manages multiple working trees from a single repo.
#   CC add-on skills occasionally attempt to use worktrees for task isolation,
#   but this conflicts with the project workflow and causes problems.
#
#   Only MUTATING subcommands are blocked (add, remove, prune, move, lock,
#   unlock, repair) plus bare `git worktree` with no subcommand (ambiguous,
#   blocked conservatively) and any unrecognized/future subcommand (fail
#   closed). Read-only/inspection subcommands (list, --help, -h) are allowed
#   through, since they don't create or mutate worktree state and are needed
#   for observability: e.g. auditing stale `.claude/worktrees/agent-*`
#   directories left behind by Agent-tool `isolation: "worktree"` subagents
#   after their branch merges. Previously this hook blocked the entire
#   `git worktree` family unconditionally, which made `git worktree list`
#   itself blocked and prevented that audit.
#
#   Both the Bash-level `git worktree` command and the EnterWorktree built-in
#   tool are blocked. This script handles the Bash layer only; EnterWorktree
#   is blocked separately by hook-block-enter-worktree.sh.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Match: git [optional-flags] worktree [subcommand-token]
# Requires `git` to appear as a command (at start of string or after shell operators &&, ||, ;, |).
# Handles interposed flags: git -C /path worktree add, git --no-pager worktree list, etc.
# The group (-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)* matches zero or more
# flag groups before `worktree`. Each group is a token starting with `-`, optionally followed by
# a non-flag value token. This prevents matching subcommands like `grep` (which don't start with
# `-`), so `git grep worktree` is NOT matched here.
#
# Capture group 2 grabs the token immediately following `worktree` (the subcommand), if any, so
# we can classify it below. Bare `git worktree` with nothing after it yields an empty capture.
#
# IMPORTANT: a compound command can contain MULTIPLE `git worktree` invocations
# (e.g. `git worktree list && git worktree add /tmp/wt`). Matching only the
# first occurrence and branching on it would let a read-only invocation at the
# start mask a mutating one later in the same command string. So every
# occurrence in the string is enumerated with `grep -oE`, and the whole
# command is blocked if ANY occurrence is not read-only.
worktree_re='(^|&&|\|\||;|\|)[[:space:]]*git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*worktree([[:space:]]+([^[:space:]|;&]+))?'

mapfile -t matches < <(printf '%s\n' "${cmd}" | grep -oE "${worktree_re}" || true)

for match in "${matches[@]}"; do
  # Re-extract the subcommand token from this specific match (last
  # whitespace-delimited field; empty if the match was bare `git worktree`).
  subcmd=""
  if [[ "${match}" =~ worktree[[:space:]]+([^[:space:]]+)$ ]]; then
    subcmd="${BASH_REMATCH[1]}"
  fi

  case "${subcmd}" in
    # Read-only / inspection: this occurrence is fine, keep checking others.
    list | --help | -h)
      continue
      ;;
    # Mutating subcommands, bare `git worktree`, or any unrecognized/future
    # subcommand: block the whole command. `repair` can rewrite worktree
    # administrative files, so it's treated as mutating despite sounding
    # read-only. Bare `git worktree` (no subcommand) is ambiguous and blocked
    # conservatively. Unknown subcommands fail closed.
    *)
      printf '%s BLOCKED GIT WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" \
        >>"${HOME}/.claude/blocked-commands.log"
      if [[ -n "${subcmd}" ]]; then
        printf '🛑 BLOCKED: git worktree %s is forbidden.\n' "${subcmd}" >&2
      else
        printf '🛑 BLOCKED: git worktree (no subcommand) is forbidden.\n' >&2
      fi
      printf '\n' >&2
      printf 'Worktrees conflict with the project workflow. There is no valid use case for them here.\n' >&2
      printf '\n' >&2
      printf '(Read-only inspection via "git worktree list" / "--help" is allowed.)\n' >&2
      printf '\n' >&2
      printf 'For task isolation, work directly on a feature branch instead:\n' >&2
      printf '  git checkout -b claude/<description>\n' >&2
      exit 2
      ;;
  esac
done
