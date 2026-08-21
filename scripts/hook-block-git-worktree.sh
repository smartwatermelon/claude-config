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
#                                 refused. Deliberately NOT path-scoped --
#                                 see the ACCEPTED TRADE-OFF note below.
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
#   ACCEPTED TRADE-OFF -- `remove`/`prune` accept ANY path, in or out of scope.
#   Unlike `add`, cleanup runs no path inspection at all. `git worktree remove
#   --force /anywhere/else` passes, and `--force` is itself allowed on purpose
#   (agent worktrees carry untracked setup files, and plain `remove` refuses
#   those). So one agent CAN destroy a peer agent's worktree along with its
#   uncommitted work. That is a real consequence, not a theoretical one.
#
#   It is accepted rather than fixed because path-scoping `remove` would undo
#   the exact thing dotfiles#200 fixed: the worktrees most needing cleanup are
#   the pre-ban ones, which by definition sit at arbitrary paths OUTSIDE
#   `.claude/worktrees/`. A scoped `remove` would leave them permanently
#   un-cleanable and still holding their branches checked out -- the original
#   bug. Scoping creation but not cleanup is the asymmetry that makes both
#   halves work.
#
#   What bounds the risk: `remove` only affects worktrees already registered in
#   `.git/config`, so it cannot reach into arbitrary directories; and cleanup
#   only ever reduces worktree count, so it cannot recreate a collision. The
#   residual exposure is peer-agent worktrees, which are registered by design.
#   If concurrent-agent worktree clobbering is ever observed in practice, the
#   fix belongs in agent orchestration (ownership metadata per worktree), not
#   in a regex hook that cannot tell one agent's path from another's.
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
#   by hook-block-enter-worktree.sh. Note that path scoping does NOT apply
#   there: EnterWorktree's tool_input carries only a `name` and no path, so the
#   caller cannot choose a location and there is nothing to scope. That hook
#   validates the name as a strict slug instead, since it becomes a directory
#   component. See its header for the reasoning.
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
  #
  # A backslash is rejected for a related but distinct reason: the argument list
  # is split with `read -r -a`, which does NOT honor backslash escaping. A path
  # written `.claude/worktrees/my\ evil` therefore arrives as two tokens, and only
  # the first (`.claude/worktrees/my`) reaches this function -- which approves it,
  # while the shell goes on to create `.claude/worktrees/my evil`. The hook would
  # be approving a path that is not the one created. Since the escape cannot be
  # honored here, a path carrying a backslash is refused rather than
  # approximated.
  case "${path}" in
    *'$'* | *'`'* | *'~'* | *'*'* | *'?'* | *'['* | *\\*) return 1 ;;
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
# `&`, `(`, `{`, and the backtick, plus the `then`/`do` keywords.
#
# Handled: `$(...)` command substitution (the `(` alternative catches it),
# `` `...` `` command substitution (the backtick alternative, which also
# terminates the captured argument list so the closing backtick is not
# swallowed into the path token), `env`/`command`/`sudo`-prefixed git,
# absolute/relative-path invocation such as `/usr/bin/git`, and git preceded by
# an opening quote of any kind -- `'`, `\"`, or ANSI-C `$'...'`.
#
# The quote alternatives close a class that was silently open: `bash -c 'git
# worktree add /tmp/evil'`, the `\"` form, and `eval $'...'` all placed git
# after a quote rather than after a separator, so none matched and every one
# skipped path_in_scope() entirely. Heredocs were never part of this class --
# `grep -oE` matches per line, so a heredoc body's `git` sits at line start and
# the `^` alternative already caught it. Enumerating heredocs as a bypass would
# have been wrong.
#
# NOT handled, and NOT closeable at this layer:
#
#   * aliases and shell functions that resolve to git
#   * obfuscation via variables, e.g. G=git; $G worktree add /tmp/evil
#   * any construction that spells `git` without the literal four characters,
#     e.g. concatenation or parameter expansion producing the name at runtime
#
# Both require knowing what a name resolves to at runtime. A PreToolUse hook
# receives the raw, unexpanded command string and never sees the shell that
# will execute it: there is no alias table, no function table, and no variable
# environment to consult. No amount of parsing -- regex or full tokenization --
# recovers that information, so these two are permanent properties of where
# this check runs, not a to-do. Closing them would require gating at execution
# time inside the shell rather than before it.
#
# These gaps predate the dotfiles#200 carve-out (the pre-change hook fails open
# on them identically), but they matter MORE now. Previously this regex gated a
# decision already fixed at "block", so a bypass merely produced an unscoped
# worktree. Now it is the sole gate deciding whether path-scoping runs at all:
# a bypassed occurrence skips path_in_scope() entirely. Treat the policy table
# at the top of this file as describing INTENT for cooperative callers, not a
# guarantee that no crafted string can evade it.
# `(env|command|sudo[[:space:]]+)*` consumes wrapper commands; `([^[:space:]]*/)?`
# consumes a leading path on the git binary itself (/usr/bin/git, ./git).
#
# The backtick is spelled via ${bt} rather than inline: a literal backtick
# inside a single-quoted string reads to shellcheck as an unexpanded command
# substitution (SC2016), and disable directives are not permitted here.
bt=$(printf '\140')
readonly bt
worktree_re="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*((env|command|sudo)[[:space:]]+)*([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&${bt}[:space:]]*[[:space:]]+)?)*worktree([[:space:]]+[^|;&){${bt}]*)?"

mapfile -t matches < <(printf '%s\n' "${cmd}" | grep -oE "${worktree_re}" || true)

for match in "${matches[@]}"; do
  # Isolate the argument list that follows the `worktree` keyword in this
  # specific occurrence, then split it into tokens.
  args="${match#*worktree}"
  tokens=()
  read -r -a tokens <<<"${args}" || true

  subcmd="${tokens[0]-}"
  # A quote-prefixed occurrence carries its closing quote into the last token,
  # so `bash -c 'git worktree list'` arrives as `list'`. Strip one trailing
  # quote so the subcommand compares equal. The path is untouched --
  # path_in_scope() strips a matched pair itself.
  subcmd="${subcmd%\'}"
  subcmd="${subcmd%\"}"

  case "${subcmd}" in
    # Read-only / inspection: this occurrence is fine, keep checking others.
    list | --help | -h)
      continue
      ;;
    # Cleanup: only ever reduces worktree count, so it cannot recreate the
    # collision conditions the ban was written for.
    #
    # Intentionally NOT path-scoped, unlike `add` above. The worktrees most in
    # need of cleanup are pre-ban ones living outside `.claude/worktrees/`, so
    # scoping here would restore the un-cleanable-worktree bug dotfiles#200
    # fixed. The cost is that an agent can remove a peer agent's worktree; see
    # the ACCEPTED TRADE-OFF note in the header before narrowing this.
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
