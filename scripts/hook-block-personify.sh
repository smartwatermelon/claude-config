#!/usr/bin/env bash
# Block commit/PR/issue text that Andrew has not visually approved.
#
# Approval lives on disk, in gate-review's approved/ directory, and is bound to
# the exact bytes he saw. The hook extracts the file the command will read its
# text from, and asks gate-review whether those bytes hash to something
# approved. No name is inferred: `check` matches on content, so a body approved
# under any label satisfies it.
#
# An earlier version read PERSONIFY_OK from the environment. That channel is
# DEAD and must not be reintroduced: the Bash tool runs in a process that does
# not inherit the interactive shell's environment, so an env-var ack is
# unsatisfiable by the human, not merely strict. Measured 2026-09-18, along
# with `$EDITOR` (no TTY on stdin or stdout). `open -a` is the one channel that
# reaches a human from here, and gate-review.sh owns it.
#
# WHY THE INPUT FORM IS CONSTRAINED. The hook sees a raw command string and
# nothing else. It can verify text only if that text is in a file it can read,
# at a path it can resolve without a shell:
#
#   -F/--file, --body-file  with an ABSOLUTE path  -> verifiable, checked
#   -m/--body "quoted text"                        -> blocked, nothing to hash
#   a RELATIVE path                                -> blocked: with `git -C`,
#       git resolves it against the repo and this hook against the tool's cwd,
#       and the two disagree silently
#   ~/... or $VAR/...                              -> blocked, same reason
#   no message flag at all                         -> blocked; editor mode has
#       no TTY here anyway, so it could never succeed
#
# All of this is for gated routes only: the route is asked first, and exempt text passes in any form (#698).
#
# PR and issue TITLES need no visual approval; they get a length check only. `gh pr edit` is
# gated only when it carries a body flag, so label and title edits pass.
# `gh pr review` follows the same rule: `--approve` alone passes, a review
# body is gated.
#
# `gh api` is gated when it sends a field named `body` or runs a GraphQL
# mutation with a body argument (claude-config#548). The one verifiable form
# is `-F body=@/absolute/path`; every inline value, and every GraphQL body,
# blocks. NOT covered: `--input <json>`, which carries the body inside a JSON
# document; blocking it outright would also block ruleset and protection
# writes that carry no prose.
#
# Covers the Bash-tool path; gh-wrapper.sh covers manual gh calls. The two are
# deliberately redundant, so neither being bypassed lets text through.
# Called by: hook-block-all.sh

set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/gate-review.sh"

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

[[ -n "${cmd}" ]] || exit 0

# Where the tool call runs. The destination of a `git commit` without `-C` and
# of every `gh` call is this directory (gate-route.sh reads its origin).
hook_cwd=$(printf '%s\n' "${input}" | jq -r '.cwd // empty')
[[ -n "${hook_cwd}" ]] || hook_cwd="${PWD}"

# KNOWN LIMITATION -- READ BEFORE RELYING ON THIS AS A SECURITY BOUNDARY.
# This is a regex approximation of shell syntax, not a shell parser, and it is
# BYPASSABLE, in the same ways and for the same reasons as the equivalent
# matcher in hook-block-main-commit.sh (see its note).
#
# Handled: command separators (`&&`, `||`, `;`, `|`, `&`, `(`, `{`, backtick),
# the `then`/`do` keywords, an opening quote of any kind, `env`/`command`/
# `sudo` wrappers, a leading path on the binary, global options before the
# subcommand, and backslash-continued lines (_join_continuations, below).
#
# NOT handled, and not closeable at this layer: aliases and shell functions,
# obfuscation through variables (`G=git; $G commit`), and any construction that
# spells the binary without those literal characters. A PreToolUse hook sees the
# raw, unexpanded string with no alias, function, or variable table to consult.
# These are properties of where the check runs, not a to-do.
#
# ${bt} avoids a literal backtick, which reads to shellcheck as SC2016.
bt=$(printf '\140')
readonly bt
_sep="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|'|\"|[[:space:]]then|[[:space:]]do)[[:space:]]*"
_wrap="((env|command|sudo)[[:space:]]+)*"
_path="([^[:space:]|;&(){${bt}]*/)?"
_optval="(\"[^\"]*\"[[:space:]]+|'[^']*'[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"

# Join backslash-continued lines into one logical line, as bash does, before
# anything else looks at the command (claude-config#595). The hook judges one
# line at a time, so without this `gh pr create --title t \` followed by
# `--body x` put the body flag on a line with no verb, and it was never checked.
#
# The join follows bash: `\<newline>` is removed outright (no space), outside
# quotes and inside double quotes. It is NOT a continuation, and the newline
# stays, inside single quotes or $'...', in a heredoc body (quoted delimiter
# or not -- heredoc text is prose, and joining it would put its words in
# command position), at the end of a comment, or when the backslash is itself
# escaped (`\\<newline>`). A plain newline still ends the line: only
# continuations join, so an approved path on one line cannot vouch for a
# command on another.
#
# Heredocs: `<<WORD`, `<<-WORD` and the quoted spellings open a body on the
# next line, up to a line that is exactly WORD (leading tabs removed for
# `<<-`). Several on one line are read in order. Same caveat as below: a
# character scanner, not a parser, so `$(...)` nesting and the like are
# approximated. One known miss: a shift inside arithmetic (`$((1<<2))`) reads
# as a heredoc operator, and no line ever closes it, so continuations after
# that line are not joined.
#
# Every awk scanner in this file runs under LC_ALL=C. macOS /usr/bin/awk
# (version 20200816) counts and cuts strings by byte, but in a UTF-8 locale its
# regex match decodes characters. A scanner that walks a line one byte at a
# time hands the match half of a multibyte character (a quoted ✗ or emoji),
# awk dies with "towc: multibyte conversion failure", set -e exits 2, and the
# command is blocked. Byte mode loses nothing: every character the scanners
# look for is ASCII, and UTF-8 never uses an ASCII byte inside a multibyte
# character, so the bytes pass through unchanged.
# test-hook-personify-multibyte.sh covers this.
_join_continuations() {
  LC_ALL=C awk '
    function flush() { print buf; buf = "" }
    BEGIN { q = 0; hd = 0; np = 0; buf = ""; joined = 0 }
    {
      line = $0
      if (hd) {
        print line
        chk = line
        if (hstrip[hd]) sub(/^\t+/, "", chk)
        if (chk == hdelim[hd]) { hd++; if (hd > np) { hd = 0; np = 0 } }
        next
      }
      n = length(line); joined = 0; i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (q == 1) { buf = buf c; if (c == "\047") q = 0; i++; continue }
        if (q == 3) {
          if (c == "\\") { buf = buf substr(line, i, 2); i += 2; continue }
          buf = buf c; if (c == "\047") q = 0; i++; continue
        }
        if (c == "\\") {
          if (i == n) { joined = 1; i++; continue }
          buf = buf substr(line, i, 2); i += 2; continue
        }
        if (q == 2) { buf = buf c; if (c == "\"") q = 0; i++; continue }
        prev = (buf == "") ? "" : substr(buf, length(buf), 1)
        if (c == "#" && (prev == "" || prev ~ /[[:space:];&|()<>]/)) {
          buf = buf substr(line, i); break
        }
        if (c == "\047") { q = 1; buf = buf c; i++; continue }
        if (c == "\"") { q = 2; buf = buf c; i++; continue }
        nx = substr(line, i + 1, 1)
        if (c == "$" && nx == "\047") { q = 3; buf = buf "$\047"; i += 2; continue }
        if (c == "<" && nx == "<" && prev != "<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2); strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          sub(/^[ \t]+/, "", rest)
          if (match(rest, /^[^ \t;&|()<>]+/)) {
            w = substr(rest, 1, RLENGTH)
            gsub(/[\047"\\]/, "", w)
            if (w != "") { np++; hdelim[np] = w; hstrip[np] = strip }
          }
          buf = buf "<<"; i += 2; continue
        }
        buf = buf c; i++
      }
      if (joined) next
      flush()
      if (q == 0 && np > 0) hd = 1
    }
    END { if (joined || buf != "") flush() }
  '
}

_joined=$(printf '%s\n' "${cmd}" | _join_continuations)

# `env FOO=1 git commit` puts an assignment between the wrapper and the binary,
# which the wrapper arm does not consume. Normalize it to the bare keyword.
_scan=$(printf '%s\n' "${_joined}" | sed -E 's/(^|[[:space:]])env[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*/\1env /g')

# A leading assignment sits between the separator and the binary and defeats
# the match. Without this pass, measured 2026-09-18, `PERSONIFY_OK=1 git
# commit -m x` returned 0 with the variable unset -- the gate was bypassable by
# typing its own name. Re-run that case against any matcher change.
_scan=$(printf '%s\n' "${_scan}" | sed -E 's/(^|&&|\|\||;|\||&|\(|\{)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+/\1 /g')

# The whole command on one line, for checks that must see past the per-line
# segments _segments produces (see _gql_has_body).
_scan_flat=$(printf '%s\n' "${_scan}" | tr '\n' ' ')
readonly _scan_flat

commit_re="${_sep}${_wrap}${_path}git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit([[:space:]]|$)"
gh_re="${_sep}${_wrap}${_path}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*(pr[[:space:]]+(create|comment|edit|review)|issue[[:space:]]+(create|comment|edit))([[:space:]]|$)"
api_re="${_sep}${_wrap}${_path}gh[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*api([[:space:]]|$)"

# A `gh api` field named exactly `body`, in every spelling gh accepts:
# `-f body=`, `-fbody=`, `--field body=`, `--field=body=`, `--raw-field body=`,
# with the key=value optionally quoted. The leading space keeps `nobody=` and
# the like out; the value runs to the next space.
_api_body_re="[[:space:]](-f|-F|--field|--raw-field)(=|[[:space:]]+)?[\"']?body=[^[:space:]]*"

# A GraphQL mutation that sets a body argument (addComment, addPullRequestReview
# and friends) carries its text inside the query string. There is no file form
# to verify: `-F query=@file` is already refused by hook-block-api-merge.sh.
_gql_body_re="mutation.*[^[:alnum:]_]body[[:space:]]*:"

# Split the line into segments at command separators, so each gated invocation
# is judged on its own flags. Checking the line as a whole would let an
# unapproved second command ride along on the first command's approved path.
_segments() {
  printf '%s\n' "${_scan}" | sed -E 's/(&&|\|\||;|\|)/\n/g'
}

# _segments splits without reading quotes, which is what keeps two commands
# inside one `bash -c "a; b"` string apart. It also cuts a quoted argument that
# holds a separator (`--title "a; b"`), and then no segment holds both the verb
# and its body file, so nothing was checked (claude-config#626). This second
# split reads quotes the way _join_continuations does (same state machine,
# heredoc bodies skipped, a newline inside quotes becomes a space) and prints
# only the segments that have a separator inside quotes. Those are verified
# whole, in addition to the quote-blind pieces, so the fix adds checks and
# removes none. A command with no quoted separator prints nothing here.
# Args: 1 prints every segment (the title check); a second arg is split instead of the whole command.
_quoted_segments() {
  printf '%s\n' "${2-${_scan}}" | LC_ALL=C awk -v all="${1:-0}" '
    function emit() { if (flag || all) print seg; seg = ""; flag = 0 }
    BEGIN { q = 0; hd = 0; np = 0; seg = ""; flag = 0 }
    {
      line = $0
      if (hd) {
        chk = line
        if (hstrip[hd]) sub(/^\t+/, "", chk)
        if (chk == hdelim[hd]) { hd++; if (hd > np) { hd = 0; np = 0 } }
        next
      }
      n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (q == 1) {
          seg = seg c; if (c == "\047") q = 0; else if (c ~ /[;&|]/) flag = 1
          i++; continue
        }
        # An escaped separator (a\;b, or inside double or dollar quotes) is
        # text as well, and _segments cuts it all the same.
        if (c == "\\") {
          if (substr(line, i + 1, 1) ~ /[;&|]/) flag = 1
          seg = seg substr(line, i, 2); i += 2; continue
        }
        if (q == 3) {
          seg = seg c; if (c == "\047") q = 0; else if (c ~ /[;&|]/) flag = 1
          i++; continue
        }
        if (q == 2) {
          seg = seg c; if (c == "\"") q = 0; else if (c ~ /[;&|]/) flag = 1
          i++; continue
        }
        prev = (seg == "") ? "" : substr(seg, length(seg), 1)
        if (c == "#" && (prev == "" || prev ~ /[[:space:];&|()<>]/)) break
        nx = substr(line, i + 1, 1)
        if (c == "\047") { q = 1; seg = seg c; i++; continue }
        if (c == "\"") { q = 2; seg = seg c; i++; continue }
        if (c == "$" && nx == "\047") { q = 3; seg = seg "$\047"; i += 2; continue }
        if (c == "<" && nx == "<" && prev != "<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2); strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          sub(/^[ \t]+/, "", rest)
          if (match(rest, /^[^ \t;&|()<>]+/)) {
            w = substr(rest, 1, RLENGTH)
            gsub(/[\047"\\]/, "", w)
            if (w != "") { np++; hdelim[np] = w; hstrip[np] = strip }
          }
          seg = seg "<<"; i += 2; continue
        }
        if ((c == "&" && nx == "&") || (c == "|" && nx == "|")) { emit(); i += 2; continue }
        if (c == ";" || c == "|") { emit(); i++; continue }
        seg = seg c; i++
      }
      if (q) seg = seg " "; else emit()
      if (q == 0 && np > 0) hd = 1
    }
    END { emit() }
  '
}

# Set while the loop over _quoted_segments runs; see _destination_for_segment.
QUOTED_PASS=0

_deny() {
  local reason="$1" surface="$2"
  {
    echo '🛑 BLOCKED: this text has not been visually approved.'
    echo ''
    echo "  surface: ${surface}"
    echo "  reason:  ${reason}"
    echo ''
    echo 'Every commit message and PR body must be read and approved in the'
    echo 'editor before it is written. To do that:'
    echo ''
    echo '  1. Write the text to a file.'
    echo "  2. ${GATE} stage --kind <kind> <label> <file>"
    echo "  3. ${GATE} open"
    echo '     Run both from the same directory: staged items are kept per'
    echo '     repo and branch of the current directory, and open shows only'
    echo "     that directory's items."
    echo '  4. Andrew reads the batch and types APPROVED in the STATUS line.'
    echo '  5. Re-run the command against the APPROVED file, absolute path.'
    echo '     open prints it on an "approved:" line; it sits under your'
    echo '     repo and branch:'
    echo "       git commit -F ${HOME}/.claude/gate-review/approved/<repo>-<branch>/<label>"
    echo "       gh pr create --title t --body-file ${HOME}/.claude/gate-review/approved/<repo>-<branch>/<label>"
    echo ''
    echo '     Use the approved copy, not the file you staged: if he edited the'
    echo '     text in the editor, his edits are what he approved and the'
    echo '     original no longer matches.'
    echo ''
    echo 'Approval is his to give. Staging and opening on his behalf is fine;'
    echo 'typing the word for him is not.'
  } >&2
  exit 2
}

# Pull the argument of a file flag out of one segment. Handles `-F path`,
# `--file=path`, `--body-file path` and the quoted forms of each.
_extract_path() {
  local seg="$1" flags="$2" p
  # `--flag=value`
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})=\"([^\"]*)\".*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})='([^']*)'.*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})=([^[:space:]]+).*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  # `--flag value`
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+\"([^\"]*)\".*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  p=$(printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+'([^']*)'.*/\\2/p" | head -1)
  [[ -n "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  printf '%s\n' "${seg}" | sed -En "s/.*[[:space:]](${flags})[[:space:]]+([^[:space:]]+).*/\\2/p" | head -1
}

# Verify one gated segment: find its text-bearing flag, resolve the path, and
# ask gate-review. Every exit from here is a decision; falling through the end
# without one would be a silent pass.
_verify_segment() {
  local seg="$1" surface="$2" inline_flags="$3" file_flags="$4" kind="$5" cap_kind="$6" path

  # Route first (#698): exempt text passes in any form. An unresolvable destination denies in here.
  _destination_for_segment "${seg}" "${kind}" "${surface}"
  _dest_exempt && return 0

  # An inline string cannot be hashed from the command line at all.
  if printf '%s\n' "${seg}" | grep -qE "[[:space:]](${inline_flags})([[:space:]]|=)"; then
    _deny "text given inline; only a file can be verified" "${surface}"
  fi

  path="$(_extract_path "${seg}" "${file_flags}")"

  if [[ -z "${path}" ]]; then
    _deny "no message file named" "${surface}"
  fi

  _verify_path "${path}" "${surface}" "${cap_kind}"
}

# Is DEST_* exempt? With DEST_ALSO_CWD the checkout must be exempt too. Any failure returns 1: full checks.
_dest_exempt() {
  local route outcome
  [[ -x "${GATE}" ]] || return 1
  local -a dest=()
  [[ -z "${DEST_REPO:-}" ]] || dest+=(--repo "${DEST_REPO}")
  [[ -z "${DEST_DIR:-}" ]] || dest+=(--dir "${DEST_DIR}")
  ((${#dest[@]} > 0)) || return 1
  route="$("${GATE}" route "${dest[@]}" 2>/dev/null)" || return 1
  outcome="${route%%$'\t'*}"
  [[ "${outcome}" == "exempt" ]] || return 1
  if [[ "${DEST_ALSO_CWD:-0}" -eq 1 ]]; then
    [[ -n "${DEST_DIR:-}" ]] || return 1
    route="$("${GATE}" route --dir "${DEST_DIR}" 2>/dev/null)" || return 1
    outcome="${route%%$'\t'*}"
    [[ "${outcome}" == "exempt" ]] || return 1
  fi
  return 0
}

# Work out where this segment's text will be published, from the command
# itself. Sets DEST_DIR and DEST_REPO (either may be empty), which _verify_path
# hands to `gate-review.sh check` so the route follows the real destination.
# A label given at staging is never consulted.
#   commit: DEST_DIR is the `-C <dir>` global option, else the hook's cwd.
#   gh/api: see _gh_destination. DEST_DIR is the hook's cwd (or cd target).
# A `-C` dir is resolved against the hook's cwd when relative. A value the hook
# cannot expand (a variable or command substitution) blocks: routing it as an
# unresolved destination would fall to the visual rule, weaker than pangram.
DEST_DIR=""
DEST_REPO=""
DEST_ALSO_CWD=0

# Reduce a repository spelling to lowercase owner/name: strip quotes, a
# scheme, a leading github.com/, a trailing slash and .git. Prints the result
# only when it is exactly owner/name; anything else (another host, a URL with a
# path left over, an empty part) prints nothing, and the caller denies.
_norm_repo() {
  local v="$1"
  v="${v//\"/}"
  v="${v//\'/}"
  v="${v,,}"
  v="${v#https://}"
  v="${v#http://}"
  v="${v#github.com/}"
  v="${v%/}"
  v="${v%.git}"
  [[ "${v}" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] && printf '%s\n' "${v}"
  return 0
}

# Count the case-insensitive matches of <regex> in <text>.
_count_re() {
  local n
  n="$(printf '%s\n' "$2" | grep -oiE -- "$1" || true)"
  [[ -n "${n}" ]] || { printf '0\n'; return 0; }
  printf '%s\n' "${n}" | wc -l | tr -d ' '
}

# Resolve the repository a gh or gh api segment publishes to. gh takes it from
# -R/--repo, from a github.com URL given as the PR or issue argument, from
# GH_REPO, or from the checkout it runs in; gh api from the endpoint's
# repos/<owner>/<name>. Every one of those is read, and every way the hook
# could read the wrong one fails closed:
#   - GH_REPO anywhere in the command: denied (the hook cannot tell which gh
#     call it reaches, and it also fills gh api's {owner}/{repo}).
#   - attached `-Rowner/name` or `-R=owner/name`: denied.
#   - a -R/--repo or github.com/ inside quoted text: denied. A quoted title
#     can carry `-R other/repo`, and the scanner cannot tell a title from an
#     option, so it takes neither.
#   - more than one distinct repository among the candidates: denied.
#   - a candidate that is not plain owner/name after normalizing: denied.
#   - gh api repositories/<id>: denied, a numeric id names no owner/name.
# A -R/--repo value or a repos/ endpoint is the destination. A github.com URL
# with no -R is the destination only if it is the PR/issue argument, which the
# scanner cannot tell from a flag value, so both it and the cwd are checked
# (DEST_ALSO_CWD) and the text must satisfy the stricter of the two. The same
# holds for gh api's repos/{owner}/{repo}, which gh fills from the checkout.
# A repos/ endpoint is read only where a word starts with it (optionally after
# a quote, a leading /, or an https://host), so `-F body=@/tmp/repos/o/n/msg`
# is not mistaken for one.
_gh_destination() {
  local seg="$1" kind="$2" surface="$3" blank flags urls paths c n placeholder=0
  local -a cands=()
  if printf '%s\n' "${_joined}" | tr '\n' ' ' | grep -qE '(^|[^A-Za-z0-9_])GH_REPO='; then
    _deny "GH_REPO sets the destination repository outside the command; drop it and use gh -R <owner/name>" "${surface}"
  fi
  if printf '%s\n' "${seg}" | grep -qE -- '[[:space:]]-R[^[:space:]]'; then
    _deny "attached -R<value> form; write -R <owner/name> with a space" "${surface}"
  fi
  blank="$(printf '%s\n' "${seg}" | sed -E "s/\"[^\"]*\"/\"\"/g; s/'[^']*'/''/g")"
  for c in '[[:space:]](-R|--repo)([[:space:]]|=|$)' 'github\.com/'; do
    n="$(_count_re "${c}" "${seg}")"
    if [[ "${n}" != "$(_count_re "${c}" "${blank}" || true)" ]]; then
      _deny "a repository (-R, --repo or github.com/) appears inside quoted text; the hook cannot tell it from the real option; name the repository outside quotes and keep it out of titles" "${surface}"
    fi
  done
  if [[ "${kind}" == "api" ]] && printf '%s\n' "${seg}" | grep -qE -- "(^|[[:space:]\"'/])repositories/"; then
    _deny "gh api repositories/<id> names the repository by number; use repos/<owner>/<name>" "${surface}"
  fi
  flags="$(printf '%s\n' "${seg}" |
    grep -oE -- "[[:space:]](-R|--repo)(=|[[:space:]]+)(\"[^\"]*\"|'[^']*'|[^[:space:]]+)" |
    sed -E 's/^[[:space:]]*(-R|--repo)(=|[[:space:]]+)//' || true)"
  urls="$(printf '%s\n' "${seg}" |
    grep -oiE -- "(^|[^.[:alnum:]-])github\.com/[^[:space:]\"'/]+/[^[:space:]\"'/]+" |
    sed -E 's#^.*[Gg][Ii][Tt][Hh][Uu][Bb]\.[Cc][Oo][Mm]/##' || true)"
  paths=""
  if [[ "${kind}" == "api" ]]; then
    paths="$(printf '%s\n' "${seg}" |
      grep -oE -- "(^|[[:space:]])[\"']?(https?://[^/[:space:]\"']+)?/?repos/[^[:space:]\"']*" |
      sed -E "s#^[[:space:]]*[\"']?(https?://[^/[:space:]\"']+)?/?repos/##" || true)"
  fi
  case "${flags}${urls}${paths}" in
    *'$'* | *"${bt}"*)
      c="${flags}${urls}${paths}"
      _deny "cannot resolve the repository from '${c//$'\n'/ }'; name it literally" "${surface}"
      ;;
    *) ;;
  esac
  while IFS= read -r c; do
    [[ -n "${c}" ]] || continue
    # gh api fills {owner}/{repo} from the checkout (GH_REPO is denied above).
    if [[ "${c}" == '{owner}/{repo}'* ]]; then
      placeholder=1
      continue
    fi
    if [[ "${c}" != */* ]]; then
      _deny "cannot resolve the repository from 'repos/${c}'" "${surface}"
    fi
    # An endpoint path runs on past owner/name (repos/o/n/issues/1/comments).
    if [[ "${c}" == */*/* ]]; then
      c="${c%%/*}/$(n="${c#*/}"; printf '%s' "${n%%/*}")"
    fi
    cands+=("${c}")
  done <<<"${paths}"
  while IFS= read -r c; do
    [[ -n "${c}" ]] && cands+=("${c}")
  done <<<"${flags}"$'\n'"${urls}"
  DEST_REPO=""
  DEST_ALSO_CWD=0
  for c in "${cands[@]}"; do
    n="$(_norm_repo "${c}")"
    [[ -n "${n}" ]] || _deny "cannot resolve '${c}' to a single owner/name repository" "${surface}"
    if [[ -n "${DEST_REPO}" && "${DEST_REPO}" != "${n}" ]]; then
      _deny "the command names more than one repository (${DEST_REPO}, ${n}); name exactly one" "${surface}"
    fi
    DEST_REPO="${n}"
  done
  if [[ -n "${DEST_REPO}" ]] && [[ "${placeholder}" -eq 1 || ( -z "${flags}" && -z "${paths}" ) ]]; then
    DEST_ALSO_CWD=1
  fi
  return 0
}

_destination_for_segment() {
  local seg="$1" kind="$2" surface="${3:-}" pre dir="" base
  # A `cd` earlier in the same command moves the destination (_track_cd). One
  # the hook cannot follow leaves it unknown, and unknown must not fall to the
  # weaker rule. That includes every cd/pushd/popd word _track_cd did not
  # consume: one inside `$(...)`, backticks or `bash -c "..."`, or after `!`,
  # `if`, `builtin` or `command`. Counted over the whole command, so a cd
  # after the gated segment denies too (fail closed).
  if ((CD_WORDS > CD_TRACKED)); then
    CD_UNRESOLVED=1
  fi
  if [[ "${CD_UNRESOLVED}" -eq 1 ]]; then
    _deny "this command has a cd the hook cannot resolve (bare cd, cd -, a variable or substitution, a popd, or a cd/pushd inside a command substitution, backticks, bash -c, or after !, if, builtin or command); use git -C <dir> or gh -R <owner/name> so the destination is explicit" "${surface}"
  fi
  if [[ "${CD_SEEN}" -eq 1 && "${_joined}" == *[\(\)]* ]]; then
    _deny "a cd combined with parentheses leaves the destination unclear; use git -C <dir> or gh -R <owner/name> so it is explicit" "${surface}"
  fi
  # A whole segment from _quoted_segments is checked after every piece, so it
  # cannot tell which cd came before it. Any cd word in the command denies.
  if [[ "${QUOTED_PASS}" -eq 1 && "${CD_WORDS}" -gt 0 ]]; then
    _deny "a cd combined with a quoted ; && || or | leaves the destination unclear; use git -C <dir> or gh -R <owner/name> so it is explicit" "${surface}"
  fi
  base="${CD_DIR:-${hook_cwd}}"
  DEST_DIR="${base}"
  DEST_REPO=""
  case "${kind}" in
    commit)
      # Only the words before `commit` are git global options; `commit -C <sha>`
      # is not a directory.
      pre="$(printf '%s\n' "${seg}" | sed -E 's/[[:space:]]commit([[:space:]].*|$)//')"
      # --git-dir, --work-tree and the GIT_DIR / GIT_WORK_TREE variables point
      # git somewhere other than -C or the cwd, and origin would then be read
      # from the wrong place. The variables are looked for in the whole command
      # (_joined), since _scan has had leading assignments stripped.
      if printf '%s\n' "${pre}" | grep -qE -- '[[:space:]]--(git-dir|work-tree)([[:space:]]|=)' ||
        printf '%s\n' "${_joined}" | tr '\n' ' ' | grep -qE '(^|[^A-Za-z0-9_])GIT_(DIR|WORK_TREE)='; then
        _deny "--git-dir, --work-tree, GIT_DIR and GIT_WORK_TREE hide the destination repository; use git -C <dir> instead" "${surface}"
      fi
      # git applies several -C options cumulatively (`-C a -C ../b` is b's
      # sibling of a), and _extract_path would read only one of them.
      if (($(printf '%s\n' "${pre}" | tr -s '[:space:]' '\n' | grep -cx -- '-C' || true) > 1)); then
        _deny "more than one git -C option; git applies them cumulatively and the hook reads one; give a single -C <dir>" "${surface}"
      fi
      dir="$(_extract_path "${pre}" '-C')"
      if [[ -n "${dir}" ]]; then
        case "${dir}" in
          *'$'* | *"${bt}"*) _deny "cannot resolve the repository from git -C '${dir}'" "${surface}" ;;
          *) ;;
        esac
        # A bare or leading `~` is the user's home, as the shell would expand it.
        if [[ "${dir:0:1}" == "~" && ( ${#dir} -eq 1 || "${dir:1:1}" == "/" ) ]]; then
          dir="${HOME}${dir:1}"
        fi
        case "${dir}" in
          /*) DEST_DIR="${dir}" ;;
          *) DEST_DIR="${base}/${dir}" ;;
        esac
      fi
      ;;
    gh | api)
      _gh_destination "${seg}" "${kind}" "${surface}"
      ;;
    *) _deny "internal error: unknown destination kind '${kind}'" "${surface}" ;;
  esac
}

# The shared tail of every file form: the path must be absolute, exist, and
# hash to something approved.
_verify_path() {
  local path="$1" surface="$2" cap_kind="$3"
  case "${path}" in
    /*) ;;
    *) _deny "path '${path}' is not absolute; git and this hook would resolve it differently" "${surface}" ;;
  esac

  [[ -f "${path}" ]] || _deny "no such file: ${path}" "${surface}"

  [[ -x "${GATE}" ]] || _deny "gate-review.sh missing at ${GATE}; cannot verify" "${surface}"

  local -a dest=()
  [[ -z "${DEST_REPO:-}" ]] || dest+=(--repo "${DEST_REPO}")
  [[ -z "${DEST_DIR:-}" ]] || dest+=(--dir "${DEST_DIR}")

  _check_one "${path}" "${surface}" --kind "${cap_kind}" "${dest[@]}"
  # A github.com URL with no -R may be a flag value rather than the PR/issue
  # argument, so the checkout's own route must pass as well (_gh_destination).
  if [[ "${DEST_ALSO_CWD:-0}" -eq 1 && -n "${DEST_DIR:-}" ]]; then
    _check_one "${path}" "${surface}" --kind "${cap_kind}" --dir "${DEST_DIR}"
  fi
}

# Run `gate-review.sh check` once and turn its one-line failure reason into the
# deny. A Pangram-gated text with no check record gets the command that writes
# the record, not the visual-approval steps, which would not help.
_check_one() {
  local path="$1" surface="$2" err line reason=""
  shift 2
  if err="$("${GATE}" check "${path}" "$@" 2>&1 >/dev/null)"; then
    [[ -z "${err}" ]] || printf '%s\n' "${err}" >&2
    return 0
  fi
  # Router notes (repo or author unresolved) stay visible above the block;
  # the last gate-review/gate-route line is the reason.
  while IFS= read -r line; do
    case "${line}" in
      gate-review:* | gate-route:*) reason="${line}" ;;
      *) ;;
    esac
  done <<<"${err}"
  [[ -z "${err}" ]] || printf '%s\n' "${err}" | grep -vxF -- "${reason:-}" >&2 || true
  case "${reason}" in
    *'no Pangram check ran'*) _deny_unchecked "${reason}" "${path}" "${surface}" ;;
    *'gate-review: over length:'*) _deny_length "${reason}" "${surface}" ;;
    *'length checker error'*) _deny_checker "${reason}" "${surface}" ;;
    '') _deny "the bytes in ${path} do not match anything approved" "${surface}" ;;
    *) _deny "${reason}" "${surface}" ;;
  esac
}

_deny_unchecked() {
  local reason="$1" path="$2" surface="$3" hint
  hint="$("${GATE}" hint "${path}" 2>/dev/null)" || hint="(gate-review.sh hint failed; run personify's scripts/pangram_check.py < ${path})"
  {
    echo '🛑 BLOCKED: this text goes to a Pangram-gated destination and no Pangram check ran on it.'
    echo ''
    echo "  surface: ${surface}"
    echo "  reason:  ${reason}"
    echo ''
    echo 'Run the personify check on this exact file:'
    echo ''
    echo "  ${hint}"
    echo ''
    echo 'PASS, FAIL and SKIPPED all leave a record; an error does not. Then'
    echo 're-run the same command. If these bytes were never approved, the'
    echo 'next attempt will say so.'
  } >&2
  exit 2
}

_deny_length() {
  {
    echo '🛑 BLOCKED: this text is over its length cap.'
    echo ''
    echo "  surface: $2"
    echo "  reason:  $1"
    echo ''
    echo 'The cap is for the kind this command publishes, whatever kind the text'
    echo 'was staged as. Shorten it, then stage, approve and publish the new text.'
  } >&2
  exit 2
}

_deny_unmeasured() {
  {
    echo '🛑 BLOCKED: the hook cannot measure this title against its length cap.'
    echo ''
    echo "  surface: $2"
    echo "  reason:  $1"
    echo ''
    echo 'Give one --title as plain quoted text, then re-run the command.'
  } >&2
  exit 2
}

_deny_checker() {
  {
    echo '🛑 BLOCKED: the length checker could not run, so nothing was measured.'
    echo ''
    echo "  surface: $2"
    echo "  reason:  $1"
    echo ''
    echo 'This is not a verdict on the text. Fix the checker (personify must be'
    echo 'installed, with scripts/length_check.py), then re-run the same command.'
  } >&2
  exit 2
}

# Is this `gh api` segment writing prose? A `body` field or a GraphQL mutation
# with a body argument. Anything else (GETs, state/label/title fields, read-only
# queries) is not a text surface.
_api_is_gated() {
  printf '%s\n' "$1" | grep -qE -- "${_api_body_re}" || _gql_has_body "$1"
}

# A GraphQL query is usually written across several lines inside a quoted
# string (plain newlines, not continuations, so _join_continuations leaves
# them), and _segments puts each line in its own segment, so the mutation and
# its `body:` sit on lines with no `gh api` on them. Measured 2026-09-25: a two-line addComment passed.
# For a graphql segment, test the whole command (_scan_flat, set once at the
# top) rather than the segment. Testing only the segment is the bug this
# fixes. A match elsewhere on the line blocks too, which is the safe direction.
_gql_has_body() {
  printf '%s\n' "$1" | grep -qE 'graphql' || return 1
  printf '%s\n' "${_scan_flat}" | grep -qE -- "${_gql_body_re}"
}

# Verify every body field in one `gh api` segment. Only `-F/--field body=@<abs>`
# can pass: that form makes gh read the value from the file, so the file's bytes
# are what gets posted. `-f/--raw-field` never expands `@`, so `-f body=@/x`
# posts the literal string and is inline text like any other value.
_verify_api_segment() {
  local seg="$1" surface="API body" m flag val matches cap_kind
  _destination_for_segment "${seg}" api "${surface}"
  cap_kind="$(_api_cap_kind "${seg}")"
  # GraphQL names its target by node id, so it has no route and is never exempt.
  if _gql_has_body "${seg}"; then
    _deny "GraphQL mutation carries its body inline; use gh pr/issue comment --body-file" "${surface}"
  fi
  # As in _verify_segment: an exempt destination passes in any form (#698).
  _dest_exempt && return 0
  matches="$(printf '%s\n' "${seg}" | grep -oE -- "${_api_body_re}" || true)"
  while IFS= read -r m; do
    [[ -n "${m}" ]] || continue
    flag="$(printf '%s\n' "${m}" | sed -E 's/^[[:space:]]*(--raw-field|--field|-f|-F).*/\1/')"
    val="${m#*body=}"
    val="${val//\"/}"
    val="${val//\'/}"
    case "${flag}" in
      -F | --field) ;;
      *) _deny "text given inline (${flag} never reads a file); use -F body=@<absolute path>" "${surface}" ;;
    esac
    [[ "${val}" == @* ]] ||
      _deny "text given inline; only -F body=@<absolute path> can be verified" "${surface}"
    _verify_path "${val#@}" "${surface}" "${cap_kind}"
  done <<<"${matches}"
}

# Endpoint words only, as in _gh_destination, so a body file path cannot pick the looser cap.
_api_cap_kind() {
  local eps ep kind=""
  eps="$(printf '%s\n' "$1" |
    grep -oE -- "(^|[[:space:]])[\"']?(https?://[^/[:space:]\"']+)?/?repos/[^[:space:]\"']*" || true)"
  while IFS= read -r ep; do
    [[ -n "${ep}" ]] || continue
    if [[ "${ep}" =~ /pulls/[0-9]+/comments ]]; then
      kind="${kind:-line-comment}"
    else
      kind="pr-comment"
    fi
  done <<<"${eps}"
  printf '%s\n' "${kind:-pr-comment}"
}

# The cap kind for a gh pr/issue segment, from the verb gh_re matched.
_gh_cap_kind() {
  local verb
  verb="$(printf '%s\n' "$1" | grep -oE -- "${gh_re}" | head -1 |
    sed -E 's/.*(pr|issue)[[:space:]]+(create|comment|edit|review)([[:space:]].*)?$/\1 \2/')"
  case "${verb}" in
    'pr create' | 'pr edit') printf 'pr\n' ;;
    'issue create' | 'issue edit') printf 'issue\n' ;;
    *) printf 'pr-comment\n' ;;
  esac
}

# One line per shell word of a segment: OK or BAD, the raw word, and the word as bash would pass it.
_words() {
  printf '%s\n' "$1" | LC_ALL=C awk -v bt="${bt}" '
    function out() {
      if (inword) printf "%s\037%s\037%s\n", (bad ? "BAD" : "OK"), raw, dec
      inword = 0; bad = 0; raw = ""; dec = ""
    }
    {
      n = length($0); q = 0; i = 1; inword = 0; bad = 0; raw = ""; dec = ""
      while (i <= n) {
        c = substr($0, i, 1); nx = substr($0, i + 1, 1)
        if (q == 1) { raw = raw c; if (c == "\047") q = 0; else dec = dec c; i++; continue }
        if (q == 2) {
          raw = raw c
          if (c == "\\") {
            raw = raw nx
            dec = dec ((nx == "$" || nx == bt || nx == "\"" || nx == "\\") ? nx : c nx)
            i += 2; continue
          }
          if (c == "\"") { q = 0; i++; continue }
          if (c == "$" || c == bt) bad = 1
          dec = dec c; i++; continue
        }
        if (c == " " || c == "\t") { out(); i++; continue }
        if (c == "~" && raw == "") bad = 1
        inword = 1; raw = raw c
        if (c == "\\") { if (nx == "") bad = 1; raw = raw nx; dec = dec nx; i += 2; continue }
        if (c == "\047") { q = 1; i++; continue }
        if (c == "\"") { q = 2; i++; continue }
        if (c == "$" || c == bt || c == "*" || c == "?" || c == "[" || c == "{") bad = 1
        dec = dec c; i++
      }
      if (q) bad = 1
      out()
    }'
}

# Measure the --title of one gh pr/issue create|edit segment. A title the words cannot pin down is denied.
_check_titles() {
  local seg="$1" kind="$2" surface="PR/issue title" tag raw dec want=0 count=0
  local value="" value_bad=0 problem="" words
  words="$(_words "${seg}")"
  while IFS=$'\037' read -r tag raw dec; do
    if ((want)); then
      want=0
      value="${dec}"
      [[ "${tag}" == "OK" ]] || value_bad=1
      continue
    fi
    [[ "${tag}" == "OK" ]] || dec="${raw}"
    # A word holding a whole command (bash -c "gh pr edit --title ...") is checked as one.
    if [[ "${tag}" == "OK" && "${dec}" == *[[:space:]]* ]] && printf '%s\n' "${dec}" | grep -qE "${gh_re}"; then
      _check_titles_in "${dec}"
    fi
    case "${dec}" in
      -t | --title)
        count=$((count + 1))
        want=1
        ;;
      -t=* | --title=*)
        count=$((count + 1))
        value="${dec#*=}"
        [[ "${tag}" == "OK" ]] || value_bad=1
        ;;
      --*) ;;
      -*)
        [[ "${dec}" =~ ^-[A-Za-z]*t ]] && problem="attached or combined -t ('${raw}'); write -t <title> or --title <title>"
        ;;
      *) ;;
    esac
  done <<<"${words}"
  ((count > 0)) || [[ -n "${problem}" ]] || return 0
  _suspended && exit 0
  [[ -z "${problem}" ]] || _deny_unmeasured "${problem}" "${surface}"
  ((count == 1)) || _deny_unmeasured "more than one title flag; gh uses the last, and the hook measures one; give one --title" "${surface}"
  ((value_bad == 0)) || _deny_unmeasured "the title holds \$, a backtick, a glob, or an unclosed quote, so it cannot be measured; give it as plain quoted text" "${surface}"
  [[ -x "${GATE}" ]] || _deny_checker "gate-review.sh missing at ${GATE}" "${surface}"
  # Titles follow the rest of the gate: an `exempt` destination is not
  # measured. Routing only relaxes, so a destination the hook cannot pin down
  # here (any cd in the command, or one _destination_for_segment would deny)
  # is not routed, and the title is measured.
  local where="" drepo="" ddir="" dalso=0
  if ((CD_WORDS == 0)); then
    where="$(
      QUOTED_PASS=0
      _destination_for_segment "${seg}" gh "${surface}" >/dev/null 2>&1 &&
        printf '%s\037%s\037%s\n' "${DEST_REPO}" "${DEST_DIR}" "${DEST_ALSO_CWD}"
    )" || where=""
  fi
  if [[ -z "${where}" ]]; then
    _measure_title "${kind}" "${value}" "${surface}"
    return 0
  fi
  IFS=$'\037' read -r drepo ddir dalso <<<"${where}"
  local -a title_route=()
  [[ -z "${drepo}" ]] || title_route+=(--repo "${drepo}")
  [[ -z "${ddir}" ]] || title_route+=(--dir "${ddir}")
  _measure_title "${kind}" "${value}" "${surface}" "${title_route[@]}"
  # As in _verify_path: a github.com URL with no -R may not be the argument,
  # so the checkout's own route must pass too.
  if [[ "${dalso}" == 1 && -n "${ddir}" ]]; then
    _measure_title "${kind}" "${value}" "${surface}" --dir "${ddir}"
  fi
}

# One `gate-review.sh measure` call for a title; every outcome but 0 denies.
# Exit 1 with no "over by" line is a usage error, not an overrun, so it is
# labeled a checker error like any other failure.
_measure_title() {
  local kind="$1" value="$2" surface="$3" err rc=0 line reason="" over
  shift 3
  err="$("${GATE}" measure --kind "${kind}" --title="${value}" "$@" </dev/null 2>&1 >/dev/null)" || rc=$?
  ((rc != 0)) || return 0
  while IFS= read -r line; do
    case "${line}" in
      gate-review:* | gate-route:*) reason="${line}" ;;
      *) ;;
    esac
  done <<<"${err}"
  over="$(printf '%s\n' "${err}" | grep ' over by ' || true)"
  if ((rc == 1)) && [[ -n "${over}" ]]; then
    _deny_length "over length: ${over//$'\n'/; }" "${surface}"
  fi
  _deny_checker "${reason:-length checker error: gate-review.sh measure exited ${rc} with no message}" "${surface}"
}

_check_titles_in() {
  local seg tkind segs
  segs="$(_quoted_segments 1 "$1")"
  while IFS= read -r seg; do
    [[ -n "${seg}" ]] || continue
    printf '%s\n' "${seg}" | grep -qE "${gh_re}" || continue
    tkind="$(_gh_cap_kind "${seg}")"
    [[ "${tkind}" == "pr" || "${tkind}" == "issue" ]] || continue
    _check_titles "${seg}" "${tkind}"
  done <<<"${segs}"
}

# A time-boxed suspension (gate-review.sh suspended; Andrew writes the file by
# hand) lets every gated segment through. It is asked only once a segment is
# actually gated, so ungated commands neither pay for the call nor print the
# notice. A missing or non-executable gate-review.sh is not a suspension: that
# case falls through to _verify_segment, which blocks.
_suspended() {
  [[ -x "${GATE}" ]] && "${GATE}" suspended
}

# A literal `cd <dir>` or `pushd <dir>` in an earlier segment of the same
# command changes where a later gated segment runs (`cd repo && git commit`).
# CD_DIR holds the last such target; CD_UNRESOLVED is set when the target cannot
# be known (bare cd, `cd -`, a variable or substitution) and is cleared only by
# a later target that does not depend on where we were. Subshells are not
# scoped. A regex scanner cannot count parentheses through quotes and
# expansions (`(cd a && echo "(x" && true); git commit` runs in the original
# directory, but a quoted `(` hides the close), so it does not try: once any cd
# has been seen, a command that contains `(` or `)` anywhere denies every gated
# segment (CD_SEEN, checked in _destination_for_segment). Plain `cd X && ...`
# with no parentheses still resolves to X.
#
# CD_WORDS counts every cd, pushd and popd word in the whole command (a word
# being a run of letters, digits and `_./-`, so /tmp/cd/x is not one);
# CD_TRACKED counts the ones _track_cd followed. Any word it did not follow
# (inside `$(...)`, backticks or `bash -c "..."`, after `!`, `if`, `builtin`
# or `command`, and every popd) makes the destination unknown, and
# _destination_for_segment denies. A quoted title that says "cd" denies too;
# that is the fail-closed direction.
CD_DIR=""
CD_UNRESOLVED=0
CD_SEEN=0
CD_TRACKED=0
CD_WORDS="$(printf '%s\n' "${_joined}" | tr -c '[:alnum:]_./-' '\n' | grep -cxE 'cd|pushd|popd' || true)"
_track_cd() {
  local seg="$1" rest arg
  rest="$(printf '%s\n' "${seg}" | sed -E 's/^[[:space:]({]*((then|do)[[:space:]]+)?//')"
  case "${rest}" in
    cd | cd[[:space:]]* | pushd | pushd[[:space:]]*)
      CD_SEEN=1
      CD_TRACKED=$((CD_TRACKED + 1))
      ;;
    *) return 0 ;;
  esac
  rest="${rest#cd}"
  rest="${rest#pushd}"
  # Skip option words (`cd -P dir`), but a lone `-` is the previous directory.
  while [[ "${rest}" =~ ^[[:space:]]+-[A-Za-z-]+([[:space:]]|$) ]]; do
    rest="$(printf '%s\n' "${rest}" | sed -E 's/^[[:space:]]+-[A-Za-z-]+//')"
  done
  rest="${rest#"${rest%%[![:space:]]*}"}"
  case "${rest}" in
    \"*) arg="${rest:1}"; arg="${arg%%\"*}" ;;
    "'"*) arg="${rest:1}"; arg="${arg%%\'*}" ;;
    *) arg="${rest%%[[:space:]\)\}]*}" ;;
  esac
  case "${arg}" in
    '' | - | *'$'* | *"${bt}"*)
      CD_UNRESOLVED=1
      return 0
      ;;
    *) ;;
  esac
  if [[ "${arg:0:1}" == "~" && ( ${#arg} -eq 1 || "${arg:1:1}" == "/" ) ]]; then
    arg="${HOME}${arg:1}"
  fi
  case "${arg}" in
    /*)
      CD_DIR="${arg}"
      CD_UNRESOLVED=0
      ;;
    *)
      # Relative to a directory we may not know: only resolvable when we do.
      if [[ "${CD_UNRESOLVED}" -eq 0 ]]; then
        CD_DIR="${CD_DIR:-${hook_cwd}}/${arg}"
      fi
      ;;
  esac
  return 0
}

# `git commit --amend --no-edit` and `-C <sha>` reuse an existing message and
# author no new text, but they name no file either, so they fall to the
# no-message-file branch and block. That is the decided behaviour (2026-09-18):
# the simple rule first, revisit if it fires repeatedly on genuinely unchanged
# text.
# A verb run through `xargs`, or through `env -C/--chdir <dir>`, never matches
# the wrapper list above, so it was never seen (claude-config#626). Neither can
# be verified anyway: xargs adds arguments from stdin, and env -C moves the
# destination. Found loosely (the verb word anywhere after the wrapper) and
# denied, approved or not. A gh call counts only when it carries a body, the
# same rule as below.
_wrapped_verb_re="(^|[^[:alnum:]_.-])(git[[:space:]](.*[[:space:]])?commit([[:space:]]|$)|gh[[:space:]](.*[[:space:]])?((pr|issue)[[:space:]]+(create|comment|edit|review)|api)[[:space:]](.*[[:space:]])?((-b|--body|-F|--body-file)([[:space:]]|=)|[^[:space:]]*body=))"
_wrapper_re="(^|[^[:alnum:]_.-])(xargs([[:space:]]|$)|env[[:space:]]+([^[:space:]]+[[:space:]]+)*(-C|--chdir)([[:space:]]|=|/))"

_gate_segment() {
  local seg="$1" pre cap_kind
  if printf '%s\n' "${seg}" | grep -qE "${_wrapped_verb_re}"; then
    # Only a wrapper before the verb counts: `git commit -F f | xargs echo` is
    # not wrapped.
    pre="$(printf '%s\n' "${seg}" | sed -E 's/(^|[^[:alnum:]_.-])(git|gh)[[:space:]].*$//')"
    if printf '%s\n' "${pre}" | grep -qE "${_wrapper_re}"; then
      _suspended && exit 0
      _deny "xargs and env -C run the command with arguments or a directory the hook cannot see; run git -C <dir> commit or gh -R <owner/name> directly" "commit message or PR/issue body"
    fi
  fi
  if printf '%s\n' "${seg}" | grep -qE "${commit_re}"; then
    _suspended && exit 0
    _verify_segment "${seg}" "commit message" '-m|--message' '-F|--file' commit commit
  elif printf '%s\n' "${seg}" | grep -qE "${gh_re}"; then
    # Titles get a length check (_check_titles) and still no visual approval; only a body flag gates here.
    if printf '%s\n' "${seg}" | grep -qE '[[:space:]](-b|--body|-F|--body-file)([[:space:]]|=)'; then
      _suspended && exit 0
      cap_kind="$(_gh_cap_kind "${seg}")"
      _verify_segment "${seg}" "PR/issue body" '-b|--body' '-F|--body-file' gh "${cap_kind}"
    fi
  elif printf '%s\n' "${seg}" | grep -qE "${api_re}"; then
    if _api_is_gated "${seg}"; then
      _suspended && exit 0
      _verify_api_segment "${seg}"
    fi
  fi
  return 0
}

while IFS= read -r seg; do
  [[ -n "${seg}" ]] || continue
  _track_cd "${seg}"
  _gate_segment "${seg}"
done < <(_segments)

# Whole segments whose quoted arguments hold a separator (claude-config#626).
# No _track_cd here: the pieces above already counted every cd, and counting
# one twice could hide an untracked one.
QUOTED_PASS=1
quoted="$(_quoted_segments)"
while IFS= read -r seg; do
  [[ -n "${seg}" ]] || continue
  _gate_segment "${seg}"
done <<<"${quoted}"

# Titles, over whole quote-aware segments so a quoted separator or newline stays inside its title.
_check_titles_in "${_scan}"

exit 0
