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
# #750: `"git" commit`, and `git -C "$X" commit` (denied). Backtick or nested -C values still escape.
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
_word="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|\\$\\([^)]*\\)|${bt}[^${bt}]*${bt}|[^[:space:]|;&${bt}\"${sq}]+)"
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

# A quoted git word (`"git"`, `'/usr/bin/git'`) runs git, so drop the quotes (#750). `x"git"` stays.
_gitword="([^[:space:]\"${sq}|;&(){${bt}]*/)?git"
_qpre="(^|[[:space:]|;&(){${bt}\"${sq}])"
readonly _gitword _qpre
_scan=$(printf '%s\n' "${_scan}" | sed -E \
  -e "s#${_qpre}\"(${_gitword})\"([[:space:]]|\$)#\\1\\2\\4#g" \
  -e "s#${_qpre}${sq}(${_gitword})${sq}([[:space:]]|\$)#\\1\\2\\4#g")

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

# Backstop (#637): env -C <$... or `...`> then git commit denies unparsed; a nested $( ) defeats the env arm.
_env_subst_re="(^|[^[:alnum:]_.-])env[[:space:]]([^|;&]*[[:space:]])?(-C|--chdir)(=|[[:space:]]+)?[\"${sq}]?[\$${bt}].*git[[:space:]](.*[[:space:]])?commit([[:space:]]|$)"
if printf '%s\n' "${_scan}" | grep -qE "${_env_subst_re}"; then
  _deny_unknown_repo 'env -C with a substituted directory'
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

  # A -C dir the hook cannot read ($X, $(...), {}) denies, for env and git alike (#750).
  for d in ${env_dirs[@]+"${env_dirs[@]}"}; do
    if [[ "${d}" == *'$'* || "${d}" == *"${bt}"* || "${d}" == *'{}'* ]]; then
      _deny_unknown_repo "env -C ${d}"
    fi
  done
  for d in ${git_dirs[@]+"${git_dirs[@]}"}; do
    if [[ "${d}" == *'$'* || "${d}" == *"${bt}"* || "${d}" == *'{}'* ]]; then
      _deny_unknown_repo "git -C ${d}"
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
    echo 'Commit from a worktree on a feature branch (#792):' >&2
    echo '  git -C /absolute/path/to/repo worktree add .claude/worktrees/<name> -b claude/<branch> origin/main' >&2
    exit 2
  fi
fi

# #792: no branch moves in a primary checkout (rules: docs/INFRASTRUCTURE.md). Without -C, the repo is the tool call's cwd.
hook_cwd=$(printf '%s\n' "${input}" | jq -r '.cwd // empty')
[[ -n "${hook_cwd}" ]] || hook_cwd="${PWD}"

# Copied from hook-block-personify.sh; keep in step. Splits at && || ; | without reading quotes.
_segments() {
  printf '%s\n' "${_scan}" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

# Copied from hook-block-personify.sh (#747); keep in step. Prefixes each piece 1 if a command starts there.
_segment_starts() {
  printf '%s\n' "${_scan}" | LC_ALL=C awk '
    BEGIN { q = 0; hd = 0; np = 0; ar = 0 }
    {
      line = $0; n = length(line)
      split("", sl); split("", top)
      i = 1
      while (i <= n) {
        two = substr(line, i, 2); c = substr(line, i, 1)
        if (two == "&&" || two == "||") { sl[i] = 2; i += 2 }
        else if (c == ";" || c == "|") { sl[i] = 1; i++ }
        else i++
      }
      if (hd) {
        lead = 0
        chk = line
        if (hstrip[hd]) sub(/^\t+/, "", chk)
        if (chk == hdelim[hd]) { hd++; if (hd > np) { hd = 0; np = 0 } }
      } else {
        lead = (q == 0)
        cmt = 0; i = 1
        while (i <= n) {
          c = substr(line, i, 1); nx = substr(line, i + 1, 1)
          prev = (i == 1) ? "" : substr(line, i - 1, 1)
          top[i] = (q == 0 && !cmt)
          if (cmt) { i++; continue }
          if (q == 1) { if (c == "\047") q = 0; i++; continue }
          if (c == "\\") { i += 2; continue }
          if (q == 3 || q == 2) { if (c == (q == 3 ? "\047" : "\"")) q = 0; i++; continue }
          if (c == "#" && (prev == "" || prev ~ /[[:space:];&|()<>]/)) { cmt = 1; top[i] = 0; i++; continue }
          if (c == "\047") { q = 1; i++; continue }
          if (c == "\"") { q = 2; i++; continue }
          if (c == "$" && nx == "\047") { q = 3; i += 2; continue }
          if (c == "(" && nx == "(") { ar++; top[i + 1] = 1; i += 2; continue }
          if (c == ")" && nx == ")" && ar > 0) { ar--; top[i + 1] = 1; i += 2; continue }
          if (ar == 0 && c == "<" && nx == "<" && prev != "<" && substr(line, i + 2, 1) != "<") {
            rest = substr(line, i + 2); strip = 0
            if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
            sub(/^[ \t]+/, "", rest)
            if (match(rest, /^[^ \t;&|()<>]+/)) {
              w = substr(rest, 1, RLENGTH)
              gsub(/[\047"\\]/, "", w)
              if (w != "") { np++; hdelim[np] = w; hstrip[np] = strip }
            }
            top[i + 1] = 1; i += 2; continue
          }
          i++
        }
        if (q == 0 && np > 0) hd = 1
      }
      start = 1; ok = lead; i = 1
      while (i <= n) {
        if (i in sl) {
          print (ok ? 1 : 0) substr(line, start, i - start)
          ok = (top[i] == 1); start = i + sl[i]; i = start
        } else i++
      }
      print (ok ? 1 : 0) substr(line, start)
    }
  '
}

# One word per line, quotes honored and dropped; stops at ) < > & or a backtick. \001 marks a word with $ or a backtick.
_words() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { RS = "\001"; q = 0; w = ""; have = 0; dyn = 0 }
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q == 1) { if (c == "\047") q = 0; else w = w c; continue }
        if (q == 2) {
          if (c == "\"") q = 0
          else { if (c == "$" || c == "\140") dyn = 1; w = w c }
          continue
        }
        if (c == "\047") { q = 1; have = 1; continue }
        if (c == "\"") { q = 2; have = 1; continue }
        if (c ~ /[[:space:]]/) {
          if (have) print (dyn ? "\001" : "") w
          w = ""; have = 0; dyn = 0; continue
        }
        if (c == ")" || c == "<" || c == ">" || c == "&" || c == "\140") break
        if (c == "$") dyn = 1
        w = w c; have = 1
      }
      if (have) print (dyn ? "\001" : "") w
    }
  '
}

# Anchored at the piece start, with no quote in _lead, so quoted text never matches (#792).
_lead="^[[:space:]]*((\\(|\\{|!|if|then|do|else|elif|while|until|time)[[:space:]]+|\\()*[[:space:]]*"
_gpath="([^[:space:]|;&(){${bt}]*/)?"
_git_move="${_gpath}git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*(checkout|switch|stash[[:space:]]+branch)([[:space:]]|$)"
_gh_move="${_gpath}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*pr[[:space:]]+checkout([[:space:]]|$)"
_wrapper="((${_env_arm}|command|sudo|nohup)[[:space:]]+)*"
move_re="${_lead}${_wrapper}(${_git_move}|${_gh_move})"
cd_re="${_lead}(cd|pushd|popd)([[:space:]]|$)"
readonly _lead _gpath _git_move _gh_move _wrapper move_re cd_re

_deny_branch_unknown() {
  {
    echo "🛑 BLOCKED: $1, so this hook cannot tell whether it moves a primary checkout off its default branch (#792)."
    echo ''
    echo 'Run it with a literal path and no cd before it:'
    echo '  git -C /absolute/path/to/worktree switch <branch>'
  } >&2
  exit 2
}

_deny_branch_move() {
  local what="$1" top="$2" def="$3" base="$4"
  {
    echo "🛑 BLOCKED: ${what} would move the primary checkout off ${def}."
    echo ''
    echo "  repo: ${top}"
    echo ''
    echo 'Other Claude Code sessions share this checkout. Moving its HEAD moves'
    echo 'theirs too, and in claude-config it changes the deployed hooks (#792, #453).'
    echo "Keep it on ${def}. Make a worktree for the branch instead:"
    echo ''
    echo "  git -C '${top}' worktree add .claude/worktrees/<name> -b <branch> ${base}"
    echo ''
    echo 'then run git and edits inside .claude/worktrees/<name>. For a PR branch,'
    echo 'add the worktree from origin/<pr-branch> after git fetch.'
    echo "Switching this checkout back to ${def} is allowed, as is git checkout -- <path>."
  } >&2
  exit 2
}

# origin/HEAD (set by clone); without it, main then master, the names the commit check protects.
_default_branch() {
  local d
  if d=$(git "$@" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) && [[ -n "${d}" ]]; then
    printf '%s\n' "${d#origin/}"
  elif git "$@" show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
  elif git "$@" show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
  else
    printf 'main\n'
  fi
}

# $1 is one piece; $2 is 1 when an earlier piece ran cd, pushd or popd.
_guard_piece() {
  local piece="$1" cd_seen="$2" m git_part wrap_part part d top def base kind
  [[ "${piece}" =~ ${move_re} ]] || return 0
  m="${BASH_REMATCH[0]}"
  local args="${piece#*"${m}"}"
  if [[ "${m}" =~ (${_git_move}|${_gh_move})$ ]]; then git_part="${BASH_REMATCH[0]}"; else git_part="${m}"; fi
  wrap_part="${m%"${git_part}"}"

  # A trailing backslash continues onto the next line, which these pieces do not join.
  if [[ "${piece}" =~ \\[[:space:]]*$ ]]; then
    _deny_branch_unknown 'a branch command is continued onto another line'
  fi
  if ((cd_seen)); then
    _deny_branch_unknown 'a cd earlier in the command changes the directory'
  fi
  if [[ "${git_part}" =~ (^|[[:space:]])--(git-dir|work-tree)([[:space:]=]|$) || "${cmd}" =~ (^|[^[:alnum:]_])GIT_(DIR|WORK_TREE)= ]]; then
    _deny_branch_unknown 'GIT_DIR or --git-dir/--work-tree names the repo'
  fi

  # The cwd, then env -C and git -C values in order, as git composes them.
  local -a cargs=(-C "${hook_cwd}")
  local found
  for part in "${wrap_part}" "${git_part}"; do
    found=$(_dirs_in "${part}")
    while IFS= read -r d; do
      [[ -n "${d}" ]] || continue
      if [[ "${d}" == *'$'* || "${d}" == *"${bt}"* || "${d}" == *'{}'* ]]; then
        _deny_branch_unknown "-C ${d} is only known when the shell runs"
      fi
      if [[ "${d}" == "${tilde}" || "${d}" == "${tilde}/"* ]]; then d="${HOME}${d:1}"; fi
      cargs+=(-C "${d}")
    done <<<"${found}"
  done

  # Not a repo, or bare: git fails by itself and no shared checkout exists.
  local info common gitdir
  info=$(git "${cargs[@]}" rev-parse --path-format=absolute --git-common-dir --absolute-git-dir --show-toplevel 2>/dev/null) || return 0
  common=$(sed -n 1p <<<"${info}")
  gitdir=$(sed -n 2p <<<"${info}")
  top=$(sed -n 3p <<<"${info}")
  # A linked worktree's git dir differs from the common dir. Not guarded.
  [[ -n "${top}" && "${common}" == "${gitdir}" ]] || return 0

  def=$(_default_branch "${cargs[@]}")
  base="origin/${def}"
  git "${cargs[@]}" show-ref --verify --quiet "refs/remotes/origin/${def}" || base="${def}"

  local -a w=()
  local words
  words=$(_words "${args}")
  [[ -z "${words}" ]] || mapfile -t w <<<"${words}"
  # Read the subcommand from the END of the match, so an option value such as -c x=gh cannot decide it.
  if [[ "${git_part}" =~ ^${_gh_move}$ ]]; then
    _deny_branch_move 'gh pr checkout' "${top}" "${def}" "${base}"
  fi
  if [[ "${git_part}" =~ [[:space:]]stash[[:space:]]+branch[[:space:]]*$ ]]; then
    _deny_branch_move 'git stash branch' "${top}" "${def}" "${base}"
  fi
  if [[ "${git_part}" =~ [[:space:]]switch[[:space:]]*$ ]]; then kind=switch; else kind=checkout; fi

  local i=0 tok create='' has_create=0 detach=0 dashdash=0 pathmode=0 op='' have_op=0
  while ((i < ${#w[@]})); do
    tok="${w[i]}"
    case "${tok}" in
      --) dashdash=1; break ;;
      -b | -B | --orphan | -c | -C | --create | --force-create)
        # -c/-C are create flags only for switch; checkout has no -c/-C.
        if [[ "${kind}" == checkout && ("${tok}" == -c || "${tok}" == -C || "${tok}" == --create || "${tok}" == --force-create) ]]; then
          ((i += 1)); continue
        fi
        has_create=1; create="${w[i + 1]-}"; ((i += 2)); continue ;;
      --orphan=* | --create=* | --force-create=*) has_create=1; create="${tok#*=}" ;;
      -b?* | -B?*) has_create=1; create="${tok:2}" ;;
      -c?* | -C?*) [[ "${kind}" == switch ]] && { has_create=1; create="${tok:2}"; } ;;
      --detach) detach=1 ;;
      -d) [[ "${kind}" == switch ]] && detach=1 ;;
      -p | --patch | --pathspec-from-file | --pathspec-from-file=*) pathmode=1 ;;
      -) if ((!have_op)); then op='-'; have_op=1; fi ;;
      -*) ;;
      *) if ((!have_op)); then op="${tok}"; have_op=1; fi ;;
    esac
    ((i += 1))
  done

  if ((has_create)); then
    [[ "${create}" == "${def}" ]] && return 0
    _deny_branch_move "git ${kind} creating ${create:-a branch}" "${top}" "${def}" "${base}"
  fi
  ((detach)) && _deny_branch_move "git ${kind} --detach" "${top}" "${def}" "${base}"
  # `git checkout [<ref>] -- <paths>` and the patch/pathspec forms restore files.
  if [[ "${kind}" == checkout ]] && ((dashdash || pathmode)); then return 0; fi
  ((have_op)) || return 0
  if [[ "${op}" == $'\001'* ]]; then
    _deny_branch_unknown "the ${kind} target ${op#?} is only known when the shell runs"
  fi
  [[ "${op}" == "${def}" || "${op}" == "refs/heads/${def}" || "${op}" == HEAD ]] && return 0
  # `-`, @{-N} and other spellings of the default branch resolve to refs/heads/<default>.
  local full='' spec="${op}"
  [[ "${spec}" == '-' ]] && spec='@{-1}'
  full=$(git "${cargs[@]}" rev-parse --symbolic-full-name "${spec}" 2>/dev/null) || full=''
  [[ "${full}" == "refs/heads/${def}" ]] && return 0
  if [[ "${kind}" == checkout && "${op}" != '-' && "${op}" != *'@{'* ]]; then
    # Neither a commit nor a remote branch DWIM would create: git reads a path.
    local remote_ref=''
    remote_ref=$(git "${cargs[@]}" for-each-ref --count=1 "refs/remotes/*/${op}" 2>/dev/null) || remote_ref=''
    if ! git "${cargs[@]}" rev-parse --verify --quiet "${op}^{commit}" >/dev/null 2>&1 && [[ -z "${remote_ref}" ]]; then
      return 0
    fi
  fi
  _deny_branch_move "git ${kind} ${op}" "${top}" "${def}" "${base}"
}

pieces="$(_segments)"
starts="$(_segment_starts)"
# If the flags ever disagree with _segments, check every piece.
starts_text="$(printf '%s\n' "${starts}" | LC_ALL=C sed 's/^[01]//')"
if [[ "${starts_text}" != "${pieces}" ]]; then
  starts="$(printf '%s\n' "${pieces}" | LC_ALL=C sed 's/^/1/')"
fi
cd_seen=0
while IFS= read -r st; do
  [[ "${st:0:1}" == 1 ]] || continue
  piece="${st:1}"
  _guard_piece "${piece}" "${cd_seen}"
  if [[ "${piece}" =~ ${cd_re} ]]; then cd_seen=1; fi
done <<<"${starts}"

exit 0
