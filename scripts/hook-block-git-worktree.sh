#!/usr/bin/env bash
# Hook: Gate git worktree subcommands
#
# Purpose:
#   git worktree creates and manages multiple working trees from a single repo.
#
#   Policy INTENT (see smartwatermelon/dotfiles#200, superseding the blanket
#   ban). This table describes what the hook aims to enforce; see the KNOWN
#   LIMITATION note above `worktree_re` below for the crafted command forms
#   that evade detection entirely:
#
#     ALLOWED  list, --help, -h   read-only inspection (shipped in #154)
#     ALLOWED  remove, prune      cleanup; these only ever REDUCE worktree
#                                 count, so they cannot reintroduce the
#                                 collisions the original ban existed to
#                                 prevent. Blocking them meant any worktree
#                                 predating the ban was permanently
#                                 un-cleanable by tooling, and held its
#                                 branch checked out so `git branch -D`
#                                 refused.
#     ALLOWED  add <path>         ONLY when <path> is under `.claude/worktrees/`.
#                                 This matches the Agent tool's
#                                 `isolation: "worktree"` convention
#                                 (`.claude/worktrees/agent-<id>`), keeps every
#                                 worktree in one auditable location, and
#                                 leaves `git worktree list` able to find them.
#     BLOCKED  add <other path>   unscoped creation, which is what caused the
#                                 "which directory is *the* checkout" confusion.
#     BLOCKED  move, lock, unlock, repair
#                                 rewrite worktree administrative state.
#     BLOCKED  bare `git worktree`, unknown/future subcommands (fail closed).
#
#   Why the ban was relaxed at all: "work directly on a feature branch instead"
#   assumed one worker per checkout. Subagent-driven execution is now the
#   documented default in CLAUDE.md, and a branch is not isolation when two
#   processes share a working tree -- `git checkout -b` swaps the branch out
#   from under a concurrent agent mid-edit. See dotfiles#200 for the collision
#   that motivated this.
#
#   Both the Bash-level command and the EnterWorktree built-in tool are gated.
#   This script handles the Bash layer only; EnterWorktree is handled separately
#   by hook-block-enter-worktree.sh, which applies the same path-scoping rule.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Shared with hook-block-enter-worktree.sh: the only directory under which
# worktree creation is permitted.
readonly WORKTREE_SCOPE='.claude/worktrees'

# Decide whether an `add` target path is inside the sanctioned scope.
#
# SECURITY NOTE: a PreToolUse hook sees the RAW, UNEXPANDED command string.
# `$HOME/x`, `~/x`, and `$(cmd)` are just text here -- this hook cannot know
# what they resolve to, and must not guess. Anything whose literal form is not
# provably inside the scope is rejected. That includes `..` at any position,
# which would otherwise let `.claude/worktrees/../../elsewhere` read as scoped.
path_in_scope() {
  local path="${1}"

  # Empty path: creation with no target. Not provably in scope.
  [[ -n "${path}" ]] || return 1

  # Strip one layer of surrounding quotes, which shells would remove.
  # Anything quoted more exotically than this falls through and is rejected
  # below by the metacharacter check.
  if [[ "${path}" =~ ^\"(.*)\"$ ]] || [[ "${path}" =~ ^\'(.*)\'$ ]]; then
    path="${BASH_REMATCH[1]}"
  fi

  # Reject unexpanded shell constructs. We cannot resolve these statically,
  # so they can never be proven in-scope. Covers $VAR, ${VAR}, $(cmd),
  # backticks, ~ expansion, and glob characters.
  case "${path}" in
    *'$'* | *'`'* | *'~'* | *'*'* | *'?'* | *'['*) return 1 ;;
    # No unexpanded shell construct found; continue validating below.
    *) ;;
  esac

  # Reject path traversal anywhere in the string. Checking for the `..`
  # component specifically (rather than the substring) avoids false-rejecting
  # a legitimate name like `.claude/worktrees/agent..1`, while still catching
  # every real traversal.
  local -a parts
  IFS='/' read -r -a parts <<<"${path}"
  local part
  for part in "${parts[@]}"; do
    [[ "${part}" == ".." ]] && return 1
  done

  # Require the scope to appear as a real path prefix, and require a non-empty
  # leaf after it (so bare `.claude/worktrees` itself is not a valid target).
  # Accepts both the relative form (`.claude/worktrees/x`, `./.claude/...`)
  # and an absolute form (`/abs/repo/.claude/worktrees/x`).
  #
  # SCOPE OF THE GUARANTEE: this proves the path is SPELLED in-scope, not that
  # it lands in THIS repo's `.claude/worktrees/`. A hook cannot resolve the
  # command's working directory, so `git -C /elsewhere worktree add
  # .claude/worktrees/x` passes, as does an absolute path carrying the scope
  # literal under any parent (`/tmp/anything/.claude/worktrees/x`). Both create
  # a worktree in a real `.claude/worktrees/` directory -- just possibly not
  # this one. The value delivered is a strong convention that keeps worktrees
  # discoverable and blocks the arbitrary-location creation that caused the
  # "which directory is *the* checkout" confusion; it is not an airtight
  # containment boundary.
  [[ "${path}" == "${WORKTREE_SCOPE}/"?* ]] && return 0
  [[ "${path}" == "./${WORKTREE_SCOPE}/"?* ]] && return 0
  [[ "${path}" == /*"/${WORKTREE_SCOPE}/"?* ]] && return 0

  return 1
}

# Pull the target path out of a creation invocation's argument list.
#
# Creation accepts flags before the path (`-b <branch>`, `-B <branch>`,
# `--detach`, `--force`, ...), so the path is NOT reliably the first argument.
# Walk the tokens, consuming flags (and the value of those flags that take one),
# and return the first bare operand -- that is the path. A trailing <commit-ish>
# may follow it, which we ignore.
extract_add_path() {
  local -a tokens=("$@")
  local i=0 tok
  while ((i < ${#tokens[@]})); do
    tok="${tokens[i]}"
    case "${tok}" in
      # Flags that take a separate value argument: skip both tokens.
      -b | -B)
        ((i += 2))
        ;;
      # `--flag=value` and valueless flags: skip one token.
      --*=* | --* | -*)
        ((i += 1))
        ;;
      # First non-flag operand is the path.
      *)
        printf '%s' "${tok}"
        return 0
        ;;
    esac
  done
  # No operand found.
  return 0
}

block() {
  local reason="${1}"
  printf '%s BLOCKED GIT WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" \
    >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: %s\n' "${reason}" >&2
  printf '\n' >&2
  printf 'Worktree policy (dotfiles#200):\n' >&2
  printf '  allowed: list, --help, remove, prune\n' >&2
  printf '  allowed: creation -- only under %s/\n' "${WORKTREE_SCOPE}" >&2
  printf '  blocked: move, lock, unlock, repair\n' >&2
  printf '\n' >&2
  printf 'To create an isolated worktree, scope it to the sanctioned directory:\n' >&2
  printf '  %s/<name>\n' "${WORKTREE_SCOPE}" >&2
  printf '\n' >&2
  printf 'Keeping every worktree under one path keeps them discoverable via\n' >&2
  printf '"git worktree list". Paths containing variables, ~, globs, or ".."\n' >&2
  printf 'are rejected because a hook cannot resolve them before the shell runs.\n' >&2
  exit 2
}

# Match: git [optional-flags] worktree [rest-of-invocation]
# Requires `git` to appear as a command (at start of string or after shell operators &&, ||, ;, |).
# Handles interposed flags: `git -C /path`, `git --no-pager`, etc.
# The group (-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)* matches zero or more
# flag groups before `worktree`. Each group is a token starting with `-`, optionally followed by
# a non-flag value token. This prevents matching subcommands like `grep` (which don't start with
# `-`), so `git grep worktree` is NOT matched here.
#
# Everything after `worktree` up to the next shell operator is captured so the
# subcommand AND its arguments (needed for path-scoping creation) can be inspected.
#
# IMPORTANT: a compound command can contain MULTIPLE `git worktree` invocations.
# Matching only the first occurrence and branching on it would let a read-only
# invocation at the start mask a mutating one later in the same command string.
# So every occurrence in the string is enumerated with `grep -oE`, and the whole
# command is blocked if ANY occurrence is not permitted.
#
# KNOWN LIMITATION -- READ BEFORE RELYING ON THIS AS A SECURITY BOUNDARY.
# This is a regex approximation of shell syntax, not a shell parser, and it is
# BYPASSABLE. The separator alternation below recognizes `&&`, `||`, `;`, `|`,
# `&`, `(`, and `{`, plus the `then`/`do` keywords. It does NOT recognize:
#
#   * backticks:             echo `git ... `                   -- NOT blocked
#   * aliases and shell functions that resolve to git
#   * obfuscation via variables, e.g. G=git; $G ...
#
# Handled: `$(...)` command substitution (the `(` alternative catches it),
# `env`/`command`/`sudo`-prefixed git, and absolute/relative-path invocation
# such as `/usr/bin/git`.
#
# These gaps predate the dotfiles#200 carve-out (the pre-change hook fails open
# on them identically), but they matter MORE now. Previously this regex gated a
# decision already fixed at "block", so a bypass merely produced an unscoped
# worktree. Now it is the sole gate deciding whether path-scoping runs at all:
# a bypassed occurrence skips path_in_scope() entirely. Treat the policy table
# at the top of this file as describing INTENT, not a guarantee that no crafted
# string can evade it. Properly closing this requires real shell tokenization
# rather than a regex, which is deliberately out of scope here.
# `(env|command|sudo[[:space:]]+)*` consumes wrapper commands; `([^[:space:]]*/)?`
# consumes a leading path on the git binary itself (/usr/bin/git, ./git).
worktree_re='(^|&&|\|\||;|\||&|\(|\{|[[:space:]]then|[[:space:]]do)[[:space:]]*((env|command|sudo)[[:space:]]+)*([^[:space:]|;&(){]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*worktree([[:space:]]+[^|;&){]*)?'

mapfile -t matches < <(printf '%s\n' "${cmd}" | grep -oE "${worktree_re}" || true)

for match in "${matches[@]}"; do
  # Isolate the argument list that follows the `worktree` keyword in this
  # specific occurrence, then split it into tokens.
  args="${match#*worktree}"
  tokens=()
  read -r -a tokens <<<"${args}" || true

  subcmd="${tokens[0]-}"

  case "${subcmd}" in
    # Read-only / inspection: this occurrence is fine, keep checking others.
    list | --help | -h)
      continue
      ;;
    # Cleanup: only ever reduces worktree count, so it cannot recreate the
    # collision conditions the ban was written for.
    remove | prune)
      continue
      ;;
    # Creation: permitted only when the target path is provably inside the
    # sanctioned scope.
    add)
      target="$(extract_add_path "${tokens[@]:1}")"
      if path_in_scope "${target}"; then
        continue
      fi
      if [[ -n "${target}" ]]; then
        block "worktree creation outside ${WORKTREE_SCOPE}/ is forbidden (got: ${target})"
      else
        block "worktree creation without an explicit path is forbidden"
      fi
      ;;
    # Mutating administrative subcommands, bare `git worktree`, or any
    # unrecognized/future subcommand. `repair` can rewrite worktree
    # administrative files, so it's treated as mutating despite sounding
    # read-only. Bare `git worktree` (no subcommand) is ambiguous and blocked
    # conservatively. Unknown subcommands fail closed.
    "")
      block "git worktree (no subcommand) is forbidden"
      ;;
    *)
      block "git worktree ${subcmd} is forbidden"
      ;;
  esac
done
