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
#   What IS detected (#374): an out-of-scope `remove` is allowed but logged to
#   ~/.claude/blocked-commands.log under an `AUDIT GIT WORKTREE REMOVE` prefix,
#   so the post-mortem has a trail instead of silence. This is deliberately
#   observe-only -- it must never block, or it reintroduces the un-cleanable
#   pre-ban worktrees described above. It does not tell whose worktree it was;
#   that still needs ownership metadata.
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

  # A multi-token quoted match leaves the CLOSING quote on the path token
  # rather than the subcommand: `bash -c 'git worktree add
  # .claude/worktrees/ok'` arrives here as `.claude/worktrees/ok'`. That was
  # accepted only because the scope prefix match below ends in `?*`, which
  # tolerates a stray quote inside the leaf name -- the right answer for an
  # incidental reason. Strip one unmatched trailing quote so the acceptance
  # is explicit, and so tightening that match later (e.g. to an exact-segment
  # comparison) does not silently reject legitimate quoted creation.
  # Unscoped paths were and remain rejected either way. See #377.
  path="${path%\'}"
  path="${path%\"}"

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

# Pull the target path out of a subcommand's argument list.
#
# Both callers accept flags before the path (`-b <branch>`, `-B <branch>`,
# `--detach`, `--force`, ...), so the path is NOT reliably the first argument.
# Walk the tokens, consuming flags (and the value of those flags that take one),
# and return the first bare operand -- that is the path. A trailing <commit-ish>
# may follow it, which we ignore.
#
# Correct for both `add <path>` and `remove [--force] <worktree>`: --force is
# valueless, so the valueless-flag arm skips it and the path is still the first
# bare operand.
extract_path_operand() {
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
  # No operand found. Callers diverge on what that means, deliberately:
  # `add` treats an empty result as "creation with no explicit path" and
  # BLOCKS it (a path that cannot be shown in scope is not allowed); `remove`
  # treats it as "nothing to inspect" and skips the audit, since a removal with
  # no operand is rejected by git itself. Returning empty rather than failing
  # keeps that policy choice at the call site.
  return 0
}

# Observe-only counterpart to block(): records an event and RETURNS. Used for
# `remove` targeting a path outside the sanctioned scope, which stays allowed
# on purpose (see the ACCEPTED TRADE-OFF note in the header) but leaves no
# trace otherwise. A distinct prefix keeps it out of anything counting
# "BLOCKED GIT WORKTREE" -- this is an audit record, not a refusal.
# Every failure path here is swallowed. Under `set -e` an unwritable log (no
# ~/.claude on first run, full disk, bad permissions) would exit non-zero, and
# a non-zero exit from a PreToolUse hook BLOCKS the command -- turning a missing
# audit line into a refused removal, the exact outcome the header forbids
# (#398). Losing the record is bad; losing the removal is worse.
#
# Takes the offending command explicitly rather than reading the script-level
# ${cmd}, so the function is callable from anywhere and shellcheck can see the
# dependency. block() still reads ${cmd} directly; that predates this and its
# four call sites are out of scope here (#397).
warn_out_of_scope_remove() {
  local target="${1}" offending_cmd="${2}"
  printf '%s AUDIT GIT WORKTREE REMOVE (out of scope: %s): %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${target}" "${offending_cmd}" \
    >>"${HOME}/.claude/blocked-commands.log" || true
  printf '⚠️  NOTE: removing a worktree outside %s/ (%s)\n' "${WORKTREE_SCOPE}" "${target}" >&2
  printf '   Allowed, and logged for audit. If this was a peer agent'"'"'s worktree,\n' >&2
  printf '   its uncommitted work is gone -- see %s/.claude/blocked-commands.log\n' "${HOME}" >&2
}

block() {
  local reason="${1}"
  printf '%s BLOCKED GIT WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" \
    >>"${HOME}/.claude/blocked-commands.log" || true
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
# A global option's value may be QUOTED and contain spaces --
# `git -c "user.name=First Last" worktree add /tmp/evil`. The bare-token
# alternative stops at the first space, so the pattern then required `worktree`
# where `Last"` actually sits, did not match, and the command skipped
# path_in_scope() entirely: unscoped creation went through unblocked. The two
# quoted alternatives below close that. Note this is an ordinary shape a person
# writes, not a crafted bypass -- the deliberate bypasses remain as documented
# above. See claude-config#430, and #429 for the same fix in
# hook-block-main-commit.sh, from which this pattern was derived.
_optval="(\"[^\"]*\"[[:space:]]+|'[^']*'[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"
readonly _optval
worktree_re="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*((env|command|sudo)[[:space:]]+)*([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*worktree([[:space:]]+[^|;&){${bt}]*)?"

mapfile -t matches < <(printf '%s\n' "${cmd}" | grep -oE "${worktree_re}" || true)

# Commands that EXECUTE a quoted string argument. Only these turn a quoted
# occurrence into a real invocation; anything else that merely carries the
# phrase as text does not.
#
# KNOWN LIMITATION -- this carve-out fails OPEN, not closed.
#
# The lookback takes the last non-flag word before the quote. When that word is
# an unrecognized command the occurrence is treated as a MENTION and skipped, so
# `pyenv exec "git worktree add /tmp/evil"` passes: the deciding word is `exec`,
# not `pyenv`. Ordinary wrappers are unaffected, because they leave a shell
# adjacent to the quote -- `sudo bash -c`, `env bash -c`, `xargs ... bash -c`
# and `command bash -c` were all checked and still block.
#
# Widening this to fail closed would re-break the false positive it exists to
# fix: `echo`, `grep` and `printf` are precisely "unrecognized commands before a
# quoted string". Both cannot be satisfied by a lookback of this kind, and
# separating them needs real tokenization -- the same boundary the header's
# KNOWN LIMITATION block already describes. Naming the executors is the smaller
# error, since a missed exotic wrapper is one more instance of a gap class this
# hook already documents rather than a new kind of hole.
_executes_quoted_string() {
  case "$1" in
    # *sh covers sh/bash/zsh/ksh/dash and any path-qualified form.
    # `env` is exact (plus a path form): a bare *env glob would also catch
    # pyenv/rbenv/direnv/goenv, which do not execute their argument as a shell
    # string. Over-matching there is safe (it keeps the block) but inaccurate,
    # so name what is actually meant.
    *sh | eval | xargs | */xargs | env | */env) return 0 ;;
    *) return 1 ;;
  esac
}

# Cursor over `cmd`, advanced past each occurrence as it is consumed. The
# same quoted literal can appear more than once with DIFFERENT preceding
# commands (`echo "X" && bash -c "X"`), and each occurrence must be judged by
# what precedes IT. Without this, every iteration re-derived its prefix from
# the first occurrence, so a leading harmless mention masked a real executor
# later in the same command line. See #383.
_remaining="${cmd}"
_consumed=""

for match in "${matches[@]}"; do
  # Split `_remaining` at THIS occurrence: `_before` is the text preceding it
  # (with everything already consumed prepended), and `_remaining` advances
  # past it so the next iteration looks at the next occurrence.
  if [[ "${_remaining}" == *"${match}"* ]]; then
    _before="${_consumed}${_remaining%%"${match}"*}"
    _rest="${_remaining#*"${match}"}"
    _consumed="${_consumed}${_remaining%%"${match}"*}${match}"
    _remaining="${_rest}"
  else
    # Should not happen (matches came from cmd), but fail safe by keeping the
    # old whole-command view rather than silently skipping the check.
    _before="${cmd}"
  fi
  # Skip a quoted MENTION of the phrase rather than an invocation of it.
  #
  # Adding the quote characters to the separator alternation (so that
  # `bash -c 'git worktree add ...'` gets inspected) also made a quoted string
  # merely CONTAINING the phrase match. `echo "git worktree add /tmp/x"` and
  # `grep -r "git worktree add" docs/` were blocked despite executing nothing,
  # which made writing docs and tests about this hook impossible.
  #
  # The captured match is identical in both cases -- quote, phrase, quote --
  # so the match alone cannot decide. What differs is the command PRECEDING
  # the quote: `bash -c` and `eval` run the string, `echo` and `grep` do not.
  # Look back at the text before this occurrence and take the last word.
  if [[ "${match:0:1}" == "'" || "${match:0:1}" == '"' ]]; then
    prefix="${_before}"
    # Trailing whitespace off, then the final word of what came before.
    prefix="${prefix%"${prefix##*[![:space:]]}"}"
    # Walk back over flags: `bash -c 'X'` puts `-c` immediately before the
    # quote, not `bash`, so testing only the last word misses every real
    # executor invocation.
    # ANSI-C quoting puts a bare `$` immediately before the quote
    # (`bash -c $'...'`), which would otherwise read as the preceding word and
    # match no executor. Drop a trailing sigil so the real command is found.
    prefix="${prefix%$}"
    prefix="${prefix%"${prefix##*[![:space:]]}"}"
    read -r -a _pre_tokens <<<"${prefix}" || true
    preceding=""
    for ((_i = ${#_pre_tokens[@]} - 1; _i >= 0; _i--)); do
      if [[ "${_pre_tokens[_i]}" != -* ]]; then
        preceding="${_pre_tokens[_i]}"
        break
      fi
    done
    if [[ -n "${preceding}" ]] && ! _executes_quoted_string "${preceding}"; then
      continue
    fi
  fi

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
    # `remove` is still ALWAYS allowed -- the audit call cannot block. It only
    # leaves a trace when the target is outside scope, which is the peer-agent
    # clobbering case the header calls a real consequence (#374). `prune` takes
    # no path operand, so there is nothing to inspect.
    remove)
      target="$(extract_path_operand "${tokens[@]:1}")"
      if [[ -n "${target}" ]] && ! path_in_scope "${target}"; then
        warn_out_of_scope_remove "${target}" "${cmd}"
      fi
      continue
      ;;
    prune)
      continue
      ;;
    # Creation: permitted only when the target path is provably inside the
    # sanctioned scope.
    add)
      target="$(extract_path_operand "${tokens[@]:1}")"
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
