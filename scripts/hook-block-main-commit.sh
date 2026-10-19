#!/usr/bin/env bash
# Hook: Block commits directly to main/master branch
# Enforces branch-based workflow
#
# WHAT COUNTS AS A COMMIT (#429). The check must fire on `commit` in
# SUBCOMMAND position -- the first non-flag token after `git` and its global
# options -- and nowhere else. The previous version tested for a
# whitespace-delimited `commit` token anywhere in a command starting with
# `git `, which blocked read-only commands that merely mention the word:
#
#     git show HEAD # explains the commit      -> blocked, commits nothing
#     git log --oneline -- commit              -> blocked, commits nothing
#
# The same substring test also missed real commits that do not start with the
# literal `git `, because the command may be wrapper- or path-qualified:
#
#     env FOO=1 git commit -m x                -> allowed through
#     /usr/bin/git commit -m x                 -> allowed through
#
# Both directions are covered by matching subcommand position instead, using
# the same regex shape as hook-block-git-worktree.sh. See the KNOWN LIMITATION
# note above `commit_re` for what that shape does and does not catch.
#
# WHICH REPO IS JUDGED (#429). When the command carries `git -C <path>`, the
# branch is read from <path> -- the repo the command will actually act on.
# Only when there is no `-C` does the hook fall back to its own working
# directory, which is a guess: the Bash tool's cwd is stateful and may sit in
# a different repo entirely, so a fallback verdict can name a branch belonging
# to a repo the command never touches. The fallback is kept because a bare
# `git commit` genuinely does act on the cwd's repo, but the message says
# which basis was used so a surprising block can be diagnosed rather than
# puzzled over.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# KNOWN LIMITATION -- READ BEFORE RELYING ON THIS AS A SECURITY BOUNDARY.
# This is a regex approximation of shell syntax, not a shell parser, and it is
# BYPASSABLE, in the same ways and for the same reasons as the equivalent
# matcher in hook-block-git-worktree.sh (see its far longer note).
#
# Handled: command separators (`&&`, `||`, `;`, `|`, `&`, `(`, `{`, backtick),
# the `then`/`do` keywords, an opening quote of any kind, `env`/`command`/
# `sudo` wrappers, a leading path on the git binary (`/usr/bin/git`, `./git`),
# and global options before the subcommand (`-C <path>`, `-c k=v`,
# `--no-pager`, ...). Since #637 also env options (`env -i`, `env -C <dir>`),
# and `xargs ... git commit`, which is denied on any branch.
#
# NOT handled, and not closeable at this layer: aliases and shell functions
# resolving to git, obfuscation through variables (`G=git; $G commit`), and any
# construction that spells `git` without those four literal characters. A
# PreToolUse hook sees the raw, unexpanded string and has no alias, function,
# or variable table to consult. These are properties of where the check runs,
# not a to-do.
#
# The global-option arm `(-[^[:space:]]+[[:space:]]+([^-][^|;&${bt}[:space:]]*[[:space:]]+)?)*`
# consumes each leading flag plus, optionally, one non-flag value token -- so
# `-C /path` and `-c user.name=x` are stepped over while `commit` is still
# required to be the token that follows. That optional value token is what
# keeps `-C <path> commit` matching without also letting a bare `commit`
# substring elsewhere in the line satisfy the pattern.
#
# That arm covers only options BEFORE the subcommand. Flags that follow it
# (`commit -am msg`, `commit --amend`) need no handling of their own: the
# trailing `([[:space:]]|$)` is satisfied by the space that separates `commit`
# from whatever comes next, so the match ends at the subcommand and the rest
# of the line is irrelevant.
#
# The backtick is spelled via ${bt} rather than inline: a literal backtick
# inside a single-quoted string reads to shellcheck as an unexpanded command
# substitution (SC2016), and disable directives are not permitted here.
bt=$(printf '\140')
readonly bt
_optval="(\"[^\"]*\"[[:space:]]+|'[^']*'[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"
readonly _optval
sq=$(printf '\047')
tilde=$(printf '\176')
readonly sq tilde
_aval="([^[:space:]\"${sq}]|\"[^\"]*\"|${sq}[^${sq}]*${sq})*"
readonly _aval
_assign="[A-Za-z_][A-Za-z0-9_]*=${_aval}[[:space:]]+"
readonly _assign

# env options before git (#637). Value-taking options are named, so no generic arm can swallow `git`.
_word="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]|;&${bt}\"${sq}]+)"
_envtok="(-[CuSPa][[:space:]]+${_word}|--(chdir|unset|split-string|argv0|env0-from)[[:space:]]+${_word}|-[^[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=${_aval})"
readonly _word _envtok
_env_arm="([^[:space:]|;&(){${bt}]*/)?env([[:space:]]+${_envtok})*"
readonly _env_arm
_git_commit="([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit([[:space:]]|$)"
readonly _git_commit
commit_re="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*((${_env_arm}|command|sudo)[[:space:]]+)*${_git_commit}"

# xargs in command position or opening a quote, then git commit (#637): args come from stdin, so the repo is unknown.
xargs_re="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*((${_env_arm}|command|sudo)[[:space:]]+)*([^[:space:]|;&(){${bt}]*/)?xargs([[:space:]][^|;&${bt}]*)?[[:space:]\"${sq}]${_git_commit}"
readonly xargs_re

# `env FOO=1 git commit` puts an assignment between the wrapper and git, which
# the wrapper arm above does not consume. Normalize an `env` wrapper down to
# the bare keyword so the invocation still reaches the matcher.
#
# The VAR=VAL group is `*`, so this also matches an `env` carrying no
# assignments at all and rewrites it to itself. That no-op is deliberate:
# `env git commit` needs no stripping, and letting the same branch cover both
# forms avoids a second pattern. Do not "fix" the `*` to `+` — that would
# leave the zero-assignment form unnormalized for no gain.
#
# A value may be quoted and hold spaces (`FOO="a b" git commit`), so the value
# pattern steps over quoted runs. The single quote is spelled via ${sq}: it
# cannot appear inside a single-quoted sed script. All three are defined above.
_scan=$(printf '%s\n' "${cmd}" | sed -E "s/(^|[[:space:]])env[[:space:]]+(${_assign})*/\\1env /g")

# A bare leading assignment (`SKIP=x git commit`, #651) sits between the
# separator and git, and neither wrapper arm consumes it. Strip it after any
# command separator, the same approach hook-block-personify.sh uses.
_scan=$(printf '%s\n' "${_scan}" | sed -E "s/(^|&&|\\|\\||;|\\||&|\\(|\\{)[[:space:]]*(${_assign})+/\\1 /g")

_deny_unknown_repo() {
  echo "🛑 BLOCKED: $1 hides which repo this commit goes to, so its branch cannot be checked." >&2
  echo '' >&2
  echo 'Run the commit directly, with a literal path:' >&2
  echo '  git -C /absolute/path/to/repo commit ...' >&2
  exit 2
}

if printf '%s\n' "${_scan}" | grep -qE "${xargs_re}"; then
  _deny_unknown_repo 'xargs'
fi

# One -C/--chdir value (quoted, bare, -C/p, --chdir=/p). Needs a space before -C, which commit_re guarantees.
_dir_re="(^|[[:space:]])(-C|--chdir)(=|[[:space:]]+)?(\"([^\"]*)\"|${sq}([^${sq}]*)${sq}|([^[:space:]]+))"
readonly _dir_re

# Print every -C/--chdir value in $1, in order, one per line.
_dirs_in() {
  local rest="$1"
  while [[ "${rest}" =~ ${_dir_re} ]]; do
    printf '%s\n' "${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
}

if printf '%s\n' "${_scan}" | grep -qE "${commit_re}"; then
  # env -C dirs, then git -C dirs, in order: git composes several -C values, so this reproduces where it runs (#637).
  match=$(printf '%s\n' "${_scan}" | grep -oE "${commit_re}" | head -1)
  git_part="${match}"
  if [[ "${match}" =~ ${_git_commit}$ ]]; then
    git_part="${BASH_REMATCH[0]}"
  fi
  wrap_part="${match%"${git_part}"}"

  found=$(_dirs_in "${wrap_part}")
  env_dirs=()
  while IFS= read -r d; do
    if [[ -n "${d}" ]]; then env_dirs+=("${d}"); fi
  done <<<"${found}"
  found=$(_dirs_in "${git_part}")
  git_dirs=()
  while IFS= read -r d; do
    if [[ -n "${d}" ]]; then git_dirs+=("${d}"); fi
  done <<<"${found}"

  # An env -C dir the hook cannot read ($X, $(...), {}) denies. git -C "$X" keeps its old behaviour: unknown, allowed.
  for d in ${env_dirs[@]+"${env_dirs[@]}"}; do
    if [[ "${d}" == *'$'* || "${d}" == *"${bt}"* || "${d}" == *'{}'* ]]; then
      _deny_unknown_repo "env -C ${d}"
    fi
  done

  cargs=()
  shown=''
  for d in ${env_dirs[@]+"${env_dirs[@]}"} ${git_dirs[@]+"${git_dirs[@]}"}; do
    # A leading ~ is expanded by the shell before git sees it.
    if [[ "${d}" == "${tilde}" || "${d}" == "${tilde}/"* ]]; then d="${HOME}${d:1}"; fi
    cargs+=(-C "${d}")
    shown="${shown:+${shown} then }${d}"
  done

  if [[ "${#cargs[@]}" -gt 0 ]]; then
    branch=$(git "${cargs[@]}" symbolic-ref --short HEAD 2>/dev/null || echo 'unknown')
    basis="directory named by -C/--chdir: ${shown}"
  else
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo 'unknown')
    basis="current directory: $(pwd)"
  fi

  if [[ "${branch}" == 'main' || "${branch}" == 'master' ]]; then
    echo '🛑 BLOCKED: Cannot commit directly to '"${branch}"'.' >&2
    echo '' >&2
    echo "Branch resolved from ${basis}" >&2
    echo '' >&2
    echo 'Create a feature branch first:' >&2
    echo '  git checkout -b claude/feature-name' >&2
    exit 2
  fi
fi
