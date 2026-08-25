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
# `--no-pager`, ...).
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
commit_re="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*((env|command|sudo)[[:space:]]+)*([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&${bt}[:space:]]*[[:space:]]+)?)*commit([[:space:]]|$)"

# `env FOO=1 git commit` puts an assignment between the wrapper and git, which
# the wrapper arm above does not consume. Normalize an `env` wrapper down to
# the bare keyword so the invocation still reaches the matcher.
#
# The VAR=VAL group is `*`, so this also matches an `env` carrying no
# assignments at all and rewrites it to itself. That no-op is deliberate:
# `env git commit` needs no stripping, and letting the same branch cover both
# forms avoids a second pattern. Do not "fix" the `*` to `+` — that would
# leave the zero-assignment form unnormalized for no gain.
_scan=$(printf '%s\n' "${cmd}" | sed -E 's/(^|[[:space:]])env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*/\1env /g')

if printf '%s\n' "${_scan}" | grep -qE "${commit_re}"; then
  # Prefer the repo the command names. Only the -C belonging to the matched
  # git invocation is meaningful, so read it from the match rather than from
  # anywhere in the line.
  #
  # COUPLED TO commit_re: this sed needs a space before `-C` to find it, which
  # holds only because the pattern requires `[[:space:]]*` after the separator
  # and `[[:space:]]+` after `git`. If the pattern is ever relaxed to accept a
  # zero-space form (`true&&git -C /p commit`), the match could begin flush
  # against `-C` and this extraction would come back empty, silently falling
  # back to the cwd guess for a command that named its repo explicitly. Re-check
  # this extraction alongside any change to commit_re.
  match=$(printf '%s\n' "${_scan}" | grep -oE "${commit_re}" | head -1)
  git_dir=$(printf '%s\n' "${match}" | sed -En 's/.*[[:space:]]-C[[:space:]]+([^[:space:]]+).*/\1/p')

  if [[ -n "${git_dir}" ]]; then
    branch=$(git -C "${git_dir}" symbolic-ref --short HEAD 2>/dev/null || echo 'unknown')
    basis="repo named by -C: ${git_dir}"
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
