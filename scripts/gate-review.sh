#!/usr/bin/env bash
# Present proposed commit/PR text for human review in a GUI editor, and record
# what was actually saved as the approval.
#
# The approval is the saved bytes, not a yes/no: edits in the editor are what
# gets committed. Hashing those bytes is what binds one approval to one text --
# any later drift re-blocks.
#
# Approval is an explicit STATUS word, not the act of saving. Saving looked
# like the lighter-weight signal, but BBEdit does not write an unmodified
# document, so "save without editing" -- the common case, approving text as
# written -- produced no event at all. Watching mtime instead meant any write
# counted, and a concurrent run's write counted as this run's approval
# (measured 2026-09-18: a stale poller approved a batch no human had read).
# Typing one word is both detectable and unambiguous.
#
# GUI only, by design. `open -a` reaches the window server from a process with
# no TTY, which is what makes this work from an agent's tool call. Over SSH
# there is no window server, so this fails closed rather than waving text
# through ungated. See claude-config#509 for the same unsolved remote case.
#
# Usage:
#   gate-review.sh stage --kind <kind> <name> <file>   queue one artifact (under its length cap) for review
#   gate-review.sh open                  open the batch, wait for save
#   gate-review.sh hash <file>           print the approved-bytes hash
#   gate-review.sh check [--kind K] <file>   exit 0 if file matches ANY approval (and fits)
#   gate-review.sh measure --kind K [--title T] [--repo R] [--dir D] <body
#                                        length check only; body on stdin
#                                        (</dev/null for a title alone)
#   gate-review.sh personify-path        print personify's dir
#   gate-review.sh suspended             exit 0 if the gate is suspended today
#
# `check` takes no name. It hashes the input and accepts if any approved
# artifact hashes the same, which dissolves the "which approval does this
# commit correspond to" question rather than answering it: the hook sees only a
# command string, and a name it had to infer from that string would be a guess
# the human never made. The batch names are labels for reading the buffer, not
# a mapping anything depends on.

set -euo pipefail
unset CDPATH

GATE_DIR="${GATE_REVIEW_DIR:-${HOME}/.claude/gate-review}"
# Staged and approved text is kept per caller: pending/<key>/<name> and
# approved/<key>/<name>, where <key> is the caller's <repo>-<branch> (see
# _batch_key). Both used to be one flat directory shared by every session, so
# an open batched every staged item whoever staged it, and a reviewer in one
# repo approved text from another (claude-config#606). PENDING and APPROVED
# start at the roots and are narrowed to the caller's key by _use_key in stage
# and open. check and the expiry sweep read every key: the hash is what binds
# an approval, and the hook runs check from whatever cwd the Bash tool has,
# which for `git -C <repo> commit` is not the repo.
PENDING_ROOT="${GATE_DIR}/pending"
APPROVED_ROOT="${GATE_DIR}/approved"
PENDING="${PENDING_ROOT}"
APPROVED="${APPROVED_ROOT}"
GATE_KEY=""
# The router sits beside this script. Resolve the real path first: the deployed
# copy is reached through a symlink under ~/.claude/scripts.
_self="${BASH_SOURCE[0]}"
if [[ -L "${_self}" ]]; then
  _target="$(readlink "${_self}")"
  [[ "${_target}" == /* ]] || _target="$(dirname "${_self}")/${_target}"
  _self="${_target}"
fi
ROUTE_SCRIPT="$(cd "$(dirname "${_self}")" 2>/dev/null && pwd)/gate-route.sh"
unset _self _target
EDITOR_APP="${GATE_REVIEW_EDITOR:-BBEdit}"
POLL_TIMEOUT="${GATE_REVIEW_TIMEOUT:-1800}"
APPROVAL_TTL="${GATE_REVIEW_APPROVAL_TTL:-1800}"
# How long a buffer left in batches/ is kept for a later open to carry
# forward. A day, not APPROVAL_TTL: the buffer holds the reviewer's edits, and
# 30 minutes would drop them over an ABORT-then-lunch. It must stay well above
# POLL_TIMEOUT, because the sweep in _cmd_open covers every key, and a live
# review's buffer is only as new as its last save.
BUFFER_TTL="${GATE_REVIEW_BUFFER_TTL:-86400}"

mkdir -p "${PENDING_ROOT}" "${APPROVED_ROOT}"

_die() {
  printf 'gate-review: %s\n' "$1" >&2
  _kept_note
  exit 1
}

# Where the reviewer's text is, said on every way out of `open` that does not
# consume it. Set once the buffer exists; a buffer is only ever removed after
# its text went into approved/ (APPROVED) or into a newer buffer (carried).
KEPT_BATCH=""
_kept_note() {
  [[ -n "${KEPT_BATCH}" && -f "${KEPT_BATCH}" ]] || return 0
  {
    echo "gate-review: your text, with any edits, is kept at ${KEPT_BATCH}"
    echo "gate-review: the next open for these items starts from it."
  } >&2
}

# Aqua means a window server exists. Anything else -- SSH, a headless daemon --
# cannot open an editor, and must not silently pass.
_require_gui() {
  local mgr
  mgr="$(launchctl managername 2>/dev/null || echo unknown)"
  [[ "${mgr}" == "Aqua" ]] && return 0
  {
    echo "gate-review: no GUI session (launchctl managername = ${mgr})."
    echo "gate-review: text cannot be reviewed from here, so it is not approved."
    echo "gate-review: run this from a desktop session on the machine."
  } >&2
  exit 1
}

# Normalize before hashing so a trailing-newline difference between what the
# editor saved and what git receives does not read as tampering.
#
# The `$(...)` is load-bearing: it strips ALL trailing newlines, which the sed
# alone does not. _cmd_open writes a blank line before each `=== name ===`
# header, so every artifact but the last came back from _split_batch carrying
# one extra newline, and `check <the file that was staged>` failed for all of
# them. Measured 2026-09-18: staged bytes ended `body\n`, approved bytes ended
# `body\n\n`, and only the last item in a batch ever verified. Both sides must
# normalize identically or the round trip this tool exists to perform does not
# close.
_hash() {
  printf '%s' "$(sed -e 's/[[:space:]]*$//' "$1")" | sha256sum | cut -d' ' -f1
}

# Where personify's pangram_check.py records every result. Mirrors its
# config_root: an empty XDG_CONFIG_HOME falls through to ~/.config. Computed
# per call, not at load, so a test can point it at a fixture dir.
_checks_dir() {
  printf '%s/personify/checks' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

# The record key is the sha256 of the RAW bytes, which is what the check hashed
# from stdin. Not _hash: stripping trailing whitespace here would miss every
# record for a file that ends in a blank line.
_raw_sha() {
  sha256sum "$1" | cut -d' ' -f1
}

# The directory of the personify
# version Claude Code has installed. The plugin cache keeps every past version
# side by side, and a guessed one can predate a feature the check now needs:
# 2.0.1 has no Keychain lookup, so on 2026-09-24 it reported "no Pangram API
# key found" on a machine whose key was in the Keychain. Computed per call so a
# test can point CLAUDE_CONFIG_DIR at a fixture.
#
# A local install wins over a copy synced from claude.ai, because that is the
# one Claude Code loads when both exist. Without a local install, the synced
# copy is found through each bucket's manifest.json: a re-upload leaves the old
# directory beside the new one (`name` and `name~g<generation>`), and only the
# manifest's `generation` says which one loads.
_personify_path() {
  local root plugins install_path manifest dir
  root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins"
  plugins="${root}/installed_plugins.json"
  install_path="$(jq -er '.plugins["personify@personify"][0].installPath // empty' \
    "${plugins}" 2>/dev/null)" || install_path=""
  if [[ -z "${install_path}" || ! -f "${install_path}/scripts/pangram_check.py" ]]; then
    install_path=""
    for manifest in "${root}"/synced/*/manifest.json; do
      [[ -f "${manifest}" ]] || continue
      dir="$(jq -er '.plugins[] | select(.name == "personify")
          | if .generation then "personify~g\(.generation)" else "personify" end' \
        "${manifest}" 2>/dev/null | head -1)" || continue
      if [[ -n "${dir}" && -f "${manifest%/*}/${dir}/scripts/pangram_check.py" ]]; then
        install_path="${manifest%/*}/${dir}"
        break
      fi
    done
  fi
  if [[ -n "${install_path}" ]]; then
    printf '%s\n' "${install_path}"
    return 0
  fi
  printf 'personify is not installed (no personify@personify with scripts/pangram_check.py in %s, and no synced copy under %s/synced); sync it from claude.ai, or install it with: claude plugin install personify@personify\n' \
    "${plugins}" "${root}" >&2
  return 1
}

_check_hint() {
  local file="$1" install_path
  if install_path="$(_personify_path 2>&1)"; then
    printf 'python3 %s/scripts/pangram_check.py < %s\n' "${install_path}" "${file}"
  else
    printf '%s\n' "${install_path}"
  fi
}

LENGTH_KINDS="commit pr issue line-comment pr-comment code-comment docstring"

_valid_kind() {
  [[ " ${LENGTH_KINDS} " == *" $1 "* ]]
}

# 0 under the cap, 1 over, 2 checker error; LENGTH_OUT holds the checker's lines, or the error reason.
# The optional third argument is a title, measured with the body in <file>.
# Safe under errexit whatever the calling context: every failing step is caught
# here, so a silent checker is an error (2), never a shell exit that a hook
# would read as "not blocked".
LENGTH_OUT=""
_length_check() {
  local kind="$1" file="$2" dir checker rc=0 errf
  local -a title_arg=()
  (($# < 3)) || title_arg=("--title=$3")
  if ! dir="$(_personify_path 2>&1)"; then
    LENGTH_OUT="${dir}"
    return 2
  fi
  checker="${dir}/scripts/length_check.py"
  if [[ ! -f "${checker}" ]]; then
    LENGTH_OUT="no ${checker}; personify 2.1.0 or later has it, so update personify"
    return 2
  fi
  errf="$(mktemp)"
  LENGTH_OUT="$(python3 "${checker}" --kind "${kind}" "${title_arg[@]}" <"${file}" 2>"${errf}")" || rc=$?
  case "${rc}" in
    0 | 1)
      cat "${errf}" >&2
      rm -f "${errf}"
      return "${rc}"
      ;;
    *)
      LENGTH_OUT="$(grep -v '^usage:' "${errf}" | tail -1 || true)"
      [[ -n "${LENGTH_OUT}" ]] || LENGTH_OUT="length_check.py exited ${rc} with no message"
      rm -f "${errf}"
      return 2
      ;;
  esac
}

# measure --kind K [--title T] [--repo R] [--dir D]: the body is read from
# stdin; give </dev/null to measure a title alone. No text at all is a usage
# error. With --repo or --dir the destination is routed as in `check`, and an
# `exempt` route measures nothing; with neither, the text is always measured.
# Exit 0 fits, 1 over the cap (the checker's lines, prefixed gate-review:),
# 2 checker error or a route that failed. This is the one path the hook uses
# for titles, so the checker is called from _length_check only.
_cmd_measure() {
  local kind="" repo="" dir="" has_title=0 title="" flagged=0 tmp rc=0 line route outcome rule reason
  while (($# > 0)); do
    case "$1" in
      --kind)
        (($# >= 2)) || _die "measure: --kind needs a value"
        kind="$2"
        shift 2
        ;;
      --title)
        (($# >= 2)) || _die "measure: --title needs a value"
        title="$2"
        has_title=1
        shift 2
        ;;
      --title=*)
        title="${1#--title=}"
        has_title=1
        shift
        ;;
      --repo)
        (($# >= 2)) || _die "measure: --repo needs a value"
        repo="$2"
        flagged=1
        shift 2
        ;;
      --dir)
        (($# >= 2)) || _die "measure: --dir needs a value"
        dir="$2"
        flagged=1
        shift 2
        ;;
      *) _die "measure: unexpected argument: $1" ;;
    esac
  done
  [[ -n "${kind}" ]] || _die "measure: --kind is required, one of: ${LENGTH_KINDS}"
  _valid_kind "${kind}" || _die "measure: unknown --kind '${kind}'; one of: ${LENGTH_KINDS}"
  if ((flagged == 1)); then
    if ! route="$(_route_line "${repo}" "${dir}")"; then
      echo "gate-review: measure: gate-route failed, so nothing was measured" >&2
      return 2
    fi
    IFS=$'\t' read -r outcome rule reason <<<"${route}"
    [[ "${outcome}" != "exempt" ]] || return 0
  fi
  tmp="$(mktemp)"
  cat >"${tmp}"
  if [[ ! -s "${tmp}" ]] && ((has_title == 0)); then
    rm -f "${tmp}"
    _die "measure: no text; give the body on stdin, or --title with </dev/null"
  fi
  if ((has_title == 1)); then
    _length_check "${kind}" "${tmp}" "${title}" || rc=$?
  else
    _length_check "${kind}" "${tmp}" || rc=$?
  fi
  rm -f "${tmp}"
  case "${rc}" in
    0) return 0 ;;
    1)
      while IFS= read -r line; do
        printf 'gate-review: %s\n' "${line}" >&2
      done <<<"${LENGTH_OUT}"
      return 1
      ;;
    *)
      echo "gate-review: length checker error, not a verdict on the text: ${LENGTH_OUT}" >&2
      return 2
      ;;
  esac
}

_record_path() {
  local dir sha
  dir="$(_checks_dir)"
  sha="$(_raw_sha "$1")"
  printf '%s/%s.json' "${dir}" "${sha}"
}

# One header line per item. Never fails: a missing or unreadable record is
# shown, not fatal. A record always wins. With none, a `visual` route sidecar
# (written by stage) turns "no record" into the banner, so the reviewer sees
# why this item skipped the check. The line starts with `#`, so it is never
# approved and never enters the hash.
_verdict_line() {
  local name="$1" file="$2" record line route outcome rule reason
  record="$(_record_path "${file}")"
  if [[ ! -f "${record}" ]]; then
    route="${file%/*}/.route/${name}"
    if [[ -f "${route}" ]]; then
      IFS=$'\t' read -r outcome rule reason <"${route}" || true
      if [[ "${outcome}" == "visual" ]]; then
        printf '# %s: NOT PANGRAM REVIEWED (rule %s: %s)\n' "${name}" "${rule}" "${reason}"
        return 0
      fi
    fi
    printf '# %s: NO RECORD\n' "${name}"
    return 0
  fi
  if line="$(jq -er --arg n "${name}" '
      if .status == "SKIPPED"
      then "# \($n): SKIPPED (\(.word_count) words, under the floor)"
      else "# \($n): \(.status) (\(.verdict), fraction_ai \(.fraction_ai), \(.word_count) words)"
      end' "${record}" 2>/dev/null)"; then
    printf '%s\n' "${line}"
  else
    printf '# %s: UNREADABLE RECORD\n' "${name}"
  fi
}

# Delete a pending item and its route sidecar together, so a re-staged item
# never shows a stale banner.
_remove_pending() {
  local dir="$1" name="$2"
  rm -f "${dir:?}/${name}" "${dir:?}/.route/${name}"
}

_cmd_stage() {
  local name="" file="" kind="" record route outcome rule reason here line
  while (($# > 0)); do
    case "$1" in
      --kind)
        (($# >= 2)) || _die "stage: --kind needs a value"
        kind="$2"
        shift 2
        ;;
      *)
        if [[ -z "${name}" ]]; then
          name="$1"
        elif [[ -z "${file}" ]]; then
          file="$1"
        else
          _die "stage: unexpected argument: $1"
        fi
        shift
        ;;
    esac
  done
  [[ -n "${kind}" ]] || _die "stage: --kind is required, one of: ${LENGTH_KINDS}"
  _valid_kind "${kind}" || _die "stage: unknown --kind '${kind}'; one of: ${LENGTH_KINDS}"
  [[ -n "${name}" && -n "${file}" ]] || _die "usage: gate-review.sh stage --kind <kind> <name> <file>"
  [[ -f "${file}" ]] || _die "no such file: ${file}"
  [[ "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || _die "bad artifact name: ${name}"
  _prune_expired
  # Route by destination, from the repo this shell is in. Staging only
  # informs; the publish-time hook recomputes the outcome from the real
  # command. A router error (rules file missing or bad) refuses to stage.
  here="$(pwd)"
  route="$("${ROUTE_SCRIPT}" --dir "${here}")" || _die "gate-route failed; nothing staged"
  IFS=$'\t' read -r outcome rule reason <<<"${route}"
  # Before the record check, so over-cap text never costs a Pangram call.
  if [[ "${outcome}" != "exempt" ]]; then
    _length_check "${kind}" "${file}" || case $? in
      1)
        while IFS= read -r line; do
          printf 'gate-review: %s\n' "${line}" >&2
        done <<<"${LENGTH_OUT}"
        _die "over the ${kind} length cap; shorten ${file} and stage again. Nothing staged."
        ;;
      *) _die "length checker error, not a verdict on the text: ${LENGTH_OUT}. Nothing staged." ;;
    esac
  fi
  # The reviewer should see what Pangram said before approving, so a text the
  # check never saw is not staged when the destination is Pangram-gated. Any
  # result counts, FAIL and SKIPPED included: this proves the check ran, it
  # does not require a pass.
  # _record_path (defined above, near _verdict_line) keys on the raw bytes.
  record="$(_record_path "${file}")"
  if [[ "${outcome}" == "pangram" && ! -f "${record}" ]]; then
    local hint
    hint="$(_check_hint "${file}")"
    {
      echo "gate-review: no Pangram check record for ${file}."
      echo "gate-review: run the personify check on this exact file, then stage again:"
      echo "gate-review:   ${hint}"
      echo "gate-review: PASS, FAIL, and SKIPPED all leave a record; an error does not."
    } >&2
    exit 1
  fi
  _use_key
  mkdir -p "${PENDING}/.route"
  cp "${file}" "${PENDING}/${name}"
  printf '%s\t%s\t%s\n' "${outcome}" "${rule}" "${reason}" >"${PENDING}/.route/${name}"
  printf 'staged: %s (for %s)\n' "${name}" "${GATE_KEY}"
}

# Narrow PENDING and APPROVED to the caller's <repo>-<branch>, the same key
# batches/ uses, so an open batches only what was staged from here and its
# approvals land where this caller reads them. The key comes from the cwd,
# so stage and open must run from the same directory.
#
# Not a session key. Claude Code does export CLAUDE_CODE_SESSION_ID, stable
# across Bash calls, but whether it survives --resume, and whether a subagent
# gets its parent's, is unverified; if either changes it, staged items strand
# under a key the agent cannot reach. It would also have to go into the
# batches/ name, or _prior_buffers carries one session's edited text into
# another's batch by item name. Limits of repo+branch: two sessions in the
# same directory (both in one repo, working elsewhere via `git -C`) share one
# queue, and outside any repo every caller is `batch`. The FROM line in each
# batch header shows which queue the reviewer is reading.
_use_key() {
  local d
  GATE_KEY="$(_batch_key)"
  # A key directory can only be missing or a directory. A regular file there is
  # an item staged or approved under the old flat layout whose name happens to
  # equal this key; mkdir would fail on it with no useful message.
  for d in "${PENDING_ROOT}/${GATE_KEY}" "${APPROVED_ROOT}/${GATE_KEY}"; do
    if [[ -e "${d}" && ! -d "${d}" ]]; then
      _die "${d} is an item from before staging was kept per repo, and its name is this repo's key (${GATE_KEY}); it must be moved aside by hand"
    fi
  done
  PENDING="${PENDING_ROOT}/${GATE_KEY}"
  APPROVED="${APPROVED_ROOT}/${GATE_KEY}"
  mkdir -p "${PENDING}" "${APPROVED}"
}

# Items staged under the old flat layout: regular files directly in pending/.
# Nothing records whose they are, so no open may batch them: guessing would
# recreate the cross-repo approval this layout exists to stop. They are named
# on every open instead, never approved and never deleted.
_note_legacy_pending() {
  local f found=()
  for f in "${PENDING_ROOT}"/*; do
    [[ -f "${f}" ]] && found+=("${f}")
  done
  ((${#found[@]} > 0)) || return 0
  {
    echo "gate-review: ${#found[@]} item(s) were staged before staging was kept per repo and branch."
    echo "gate-review: Nothing says whose they are, so they are NOT in this batch and NOT approved:"
    for f in "${found[@]}"; do
      echo "gate-review:   ${f}"
    done
    echo "gate-review: Restage any still wanted from its own repo: gate-review.sh stage --kind <kind> <name> <file>."
    echo "gate-review: Andrew can delete these files by hand; the hooks keep agents out of gate-review/."
  } >&2
}

# Other keys that have something staged: said when this caller has nothing,
# since the usual cause is staging on one branch and opening on another.
_other_keys_with_pending() {
  local d
  for d in "${PENDING_ROOT}"/*/; do
    d="${d%/}"
    [[ -d "${d}" && "${d##*/}" != "${GATE_KEY}" ]] || continue
    compgen -G "${d}/*" >/dev/null && printf '%s\n' "${d##*/}"
  done
  return 0
}

# Where this batch's buffer lives: one file per batch, named for the caller's
# repo and branch so the BBEdit window title says whose text it is. Every
# batch used to share ${GATE_DIR}/batch.txt, so BBEdit could show, or save
# over, a buffer that belonged to another batch.
#
# No PR number: finding one means a network call (`gh pr view`) inside the
# approval path, which can hang or prompt for auth. The branch already names
# the PR, and the nonce makes the name unique.
#
# Every component is reduced to [A-Za-z0-9._-]: branch names carry `/`, and a
# repo directory can hold spaces.
_batch_path() {
  local nonce="$1" dir
  dir="${GATE_DIR}/batches"
  mkdir -p "${dir}"
  nonce="${nonce//[^A-Za-z0-9._-]/-}"
  printf '%s/%s-%s.txt\n' "${dir}" "$(_batch_key)" "${nonce}"
}

# The <repo>-<branch> part of a batch file name, or `batch` outside a repo.
_batch_key() {
  local top repo branch
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [[ -z "${top}" ]]; then
    printf 'batch\n'
    return 0
  fi
  repo="${top##*/}"
  repo="${repo//[^A-Za-z0-9._-]/-}"
  branch="$(git branch --show-current 2>/dev/null)" || branch=""
  if [[ -z "${branch}" ]]; then
    branch="$(git rev-parse --short HEAD 2>/dev/null)" || branch="unborn"
    branch="detached-${branch}"
  fi
  branch="${branch//[^A-Za-z0-9._-]/-}"
  printf '%s-%s\n' "${repo}" "${branch}"
}

# Read a buffer back WITHOUT approving anything, into $2:
#   names          the item names, one per line, in buffer order
#   body/<name>    each item's text, trailing newlines stripped
#   origin/<name>  the hash of the staged text the buffer was built from
#   previous       the `# >>> PREVIOUS TEXT` blocks from the header, verbatim
# Returns 1 on a name that could not have been staged, or a repeated one, so a
# hand-mangled buffer is left on disk rather than half carried.
_parse_buffer() {
  local file="$1" out="$2" line name="" body="" in_block=0
  mkdir -p "${out}/body" "${out}/origin"
  : >"${out}/names"
  : >"${out}/previous"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == '=== '*' ===' ]]; then
      [[ -z "${name}" ]] || printf '%s' "$(printf '%s' "${body}")" >"${out}/body/${name}"
      name="${line#=== }"
      name="${name% ===}"
      [[ "${name}" =~ ^[A-Za-z0-9._-]+$ && ! -e "${out}/body/${name}" ]] || return 1
      printf '%s\n' "${name}" >>"${out}/names"
      body=""
      continue
    fi
    if [[ -n "${name}" ]]; then
      body+="${line}"$'\n'
      continue
    fi
    # Only the reviewer's own earlier text is carried; notes are rebuilt.
    [[ "${line}" == '# >>> PREVIOUS TEXT of '* ]] && in_block=1
    if ((in_block)); then
      printf '%s\n' "${line}" >>"${out}/previous"
      [[ "${line}" == '# <<<'* ]] && in_block=0
      continue
    fi
    if [[ "${line}" =~ ^#\ ORIGIN\ ([A-Za-z0-9._-]+):\ ([0-9a-f]+)$ ]]; then
      printf '%s' "${BASH_REMATCH[2]}" >"${out}/origin/${BASH_REMATCH[1]}"
    fi
  done <"${file}"
  [[ -z "${name}" ]] || printf '%s' "$(printf '%s' "${body}")" >"${out}/body/${name}"
  return 0
}

# Quote text into the framing header, where _split_batch never reads it.
_quote() {
  sed 's/^/# | /' "$1"
  [[ -z "$(tail -c1 "$1")" ]] || echo ""
}

# Earlier buffers for this repo/branch: <key>-<pid>-<epoch>.txt, nothing else.
# The strict tail keeps branch `main` from matching `main-foo`'s files.
_prior_buffers() {
  local key="$1" f tail
  for f in "${GATE_DIR}/batches/${key}"-*.txt; do
    [[ -f "${f}" ]] || continue
    tail="${f##*/}"
    tail="${tail#"${key}"-}"
    [[ "${tail%.txt}" =~ ^[0-9]+-[0-9]+$ ]] && printf '%s\n' "${f}"
  done
  return 0
}

# Remove buffers, on every key, whose last write is older than BUFFER_TTL.
# Only an open with exactly a buffer's item set carries it forward, so a buffer
# whose set changed, or whose branch was merged and deleted, was never removed:
# batches/ grew, and each open on its key re-reported every one of them
# (claude-config#614). Each removal is named, since it is the reviewer's text.
# Only files shaped like a buffer (or its half-written .tmp) are touched; age
# is mtime, as in _prune_expired, and an unreadable mtime is left alone.
_prune_stale_buffers() {
  local now f mtime
  now="$(date +%s)"
  for f in "${GATE_DIR}/batches/"*.txt "${GATE_DIR}/batches/"*.txt.tmp; do
    [[ -f "${f}" && "${f##*/}" =~ ^[A-Za-z0-9._-]+-[0-9]+-[0-9]+\.txt(\.tmp)?$ ]] || continue
    mtime="$(stat -c %Y "${f}" 2>/dev/null || stat -f %m "${f}" 2>/dev/null)" || continue
    if ((now - mtime > BUFFER_TTL)); then
      rm -f "${f}"
      printf 'gate-review: removed stale buffer (untouched over %ss): %s\n' \
        "${BUFFER_TTL}" "${f}" >&2
    fi
  done
  return 0
}

_cmd_open() {
  local batch count waited=0 nonce status

  _use_key
  _note_legacy_pending
  count=$(find "${PENDING}" -maxdepth 1 -type f | wc -l | tr -d ' ')
  if ((count == 0)); then
    local others
    others="$(_other_keys_with_pending)"
    if [[ -n "${others}" ]]; then
      printf 'gate-review: items are staged for other repos/branches, not shown here: %s\n' \
        "${others//$'\n'/ }" >&2
    fi
    _die "nothing staged for ${GATE_KEY} (staging is kept per repo and branch)"
  fi

  _require_gui

  # One review at a time, across every key: there is one reviewer and one
  # editor. Measured 2026-09-18, back when every session shared one batch.txt
  # and one pending/: a stale poller from an interrupted session split a newer
  # batch and reported it approved, with no human involved at all.
  _refuse_if_open

  # After the refusal, so no other open is live whose buffer this could take.
  _prune_stale_buffers

  # Bound this batch to this process. _split_batch refuses a buffer carrying a
  # different id, so a stale poller cannot approve text it never wrote.
  nonce="$$-$(date +%s)"
  batch="$(_batch_path "${nonce}")"

  # Start from the reviewer's last text for these items, not the staged
  # originals. Every way out of an earlier open except APPROVED left its
  # buffer on disk; opening the staged text instead threw those edits away
  # (observed 2026-09-25: a mistyped STATUS word, then a fresh open showing
  # the original text). Only a buffer for this repo/branch with exactly the
  # staged item names is a candidate; the newest one wins.
  local work want cand prior="" skipped=() batch_items=()
  work="$(mktemp -d)"
  want="$(find "${PENDING}" -maxdepth 1 -type f -exec basename {} \; | sort)"
  local i=0
  while IFS= read -r cand; do
    [[ -n "${cand}" && "${cand}" != "${batch}" ]] || continue
    i=$((i + 1))
    if _parse_buffer "${cand}" "${work}/${i}" &&
      [[ "$(sort "${work}/${i}/names")" == "${want}" ]] &&
      [[ -z "${prior}" || "${cand}" -nt "${prior}" ]]; then
      [[ -z "${prior}" ]] || skipped+=("${prior}")
      prior="${cand}"
      rm -rf "${work}/p"
      mv "${work}/${i}" "${work}/p"
    else
      skipped+=("${cand}")
    fi
  done < <(_prior_buffers "${GATE_KEY}")

  # One buffer for the whole set: the reviewer reads and edits everything in a
  # single pass, which is the point of batching.
  {
    echo "# STATUS: PENDING"
    echo "#"
    echo "# REVIEW THESE ${count} ITEM(S), EDIT FREELY."
    echo "#"
    echo "# PANGRAM (proof the check ran; the verdict is information):"
    for f in "${PENDING}"/*; do
      _verdict_line "${f##*/}" "${f}"
    done
    echo "#"
    echo "# TO APPROVE: change PENDING above to APPROVED, then save."
    echo "# TO ABORT:   change PENDING above to ABORT, then save. Your text"
    echo "#             is kept, and the next open for these items starts from it."
    echo "#"
    echo "# An explicit word, not a bare save: BBEdit does not write an"
    echo "# unmodified document, so there is no save to detect. Leaving this"
    echo "# PENDING approves nothing, which is also what an editor autosaving"
    echo "# on close leaves behind."
    echo "#"
    echo "# To drop ONE item from the set: delete its body."
    echo "# Lines starting with # are stripped from the approved text."
    echo "#"
    echo "# FROM: ${GATE_KEY}. Only items staged from this repo and branch are"
    echo "# here; other repos and branches keep their own."
    echo "# ABORT, a timeout, or a killed wait approves nothing and leaves these"
    echo "# items staged for ${GATE_KEY}. Only the next open from this repo and"
    echo "# branch shows them again."
    echo "#"
    echo "# BATCH: ${nonce}"
    # What each item was built from, so a later open can tell the reviewer's
    # edits apart from a restage. Header lines: never approved. The same
    # names, kept in memory, are what an ABORT revokes: not re-read from
    # pending/, where another session may have staged since, and not from the
    # buffer's header, which the reviewer can edit.
    for f in "${PENDING}"/*; do
      batch_items+=("${f##*/}")
      echo "# ORIGIN ${f##*/}: $(_hash "${f}")"
    done
    if [[ -n "${prior}" ]]; then
      echo "#"
      echo "# CARRIED FORWARD: the items below are your text from the last"
      echo "# review of these items (${prior##*/}). STATUS is reset to PENDING."
      cat "${work}/p/previous"
    fi
    local n old
    for f in "${PENDING}"/*; do
      n="${f##*/}"
      old="${work}/p/body/${n}"
      [[ -n "${prior}" && -f "${old}" ]] || continue
      if [[ "$(cat "${work}/p/origin/${n}" 2>/dev/null)" != "$(_hash "${f}")" &&
        "$(_hash "${old}")" != "$(_hash "${f}")" ]]; then
        if [[ ! -s "${old}" ]]; then
          echo "# >>> ${n}: you emptied it last review, but the staged text changed"
          echo "# since, so ${n} below is the NEW staged text. Empty it again to drop it."
          echo "# <<< end of note on ${n}"
          continue
        fi
        echo "# >>> PREVIOUS TEXT of ${n}: the staged text changed since your last"
        echo "# review, so ${n} below is the NEW staged text. Your earlier text is"
        echo "# quoted here; copy what you want into ${n}. Quoted lines are never approved."
        _quote "${old}"
        echo "# <<< end of previous text of ${n}"
      elif [[ ! -s "${old}" ]]; then
        echo "# >>> ${n} is EMPTY because you emptied it last review, so it stays"
        echo "# dropped unless you add text. The staged text, for reference:"
        _quote "${f}"
        echo "# <<< end of staged text of ${n}"
      fi
    done
    for f in "${PENDING}"/*; do
      n="${f##*/}"
      old="${work}/p/body/${n}"
      echo ""
      echo "=== ${n} ==="
      if [[ -n "${prior}" && -f "${old}" ]] &&
        [[ "$(cat "${work}/p/origin/${n}" 2>/dev/null)" == "$(_hash "${f}")" ||
          "$(_hash "${old}")" == "$(_hash "${f}")" ]]; then
        cat "${old}"
        echo ""
      else
        cat "${f}"
      fi
    done
  } >"${batch}.tmp"
  # Written aside, then renamed: a kill mid-write must not leave a truncated
  # buffer under a name the next open would carry forward.
  mv "${batch}.tmp" "${batch}"
  KEPT_BATCH="${batch}"
  # A killed or interrupted wait leaves the buffer where it is; say where.
  # One trap per signal, each exiting 128 + its number, so a caller can tell
  # a Ctrl-C from a kill: one shared `exit 130` reported TERM and HUP as INT.
  trap '_kept_note; exit 130' INT
  trap '_kept_note; exit 143' TERM
  trap '_kept_note; exit 129' HUP
  if [[ -n "${prior}" ]]; then
    # Its text now lives in the new buffer, so the old file is redundant.
    rm -f "${prior}"
    printf 'gate-review: carried your text forward from %s into %s\n' \
      "${prior##*/}" "${batch##*/}" >&2
  fi
  for cand in "${skipped[@]}"; do
    printf 'gate-review: earlier buffer kept, not carried (different items): %s\n' "${cand}" >&2
  done
  rm -rf "${work}"

  printf 'opening %s item(s) in %s\n' "${count}" "${EDITOR_APP}" >&2
  open -a "${EDITOR_APP}" "${batch}" || _die "could not open ${EDITOR_APP}"

  # `open` returns as soon as the request is dispatched, so wait on the file
  # rather than on the editor. Poll the status word: it is written only by a
  # human typing it, whereas mtime moves for reasons that are not approval.
  #
  # A word that is neither keyword nor a near-miss of one does not end the
  # wait. It used to: a typo like APPORVED died as "unrecognized", and the
  # whole batch had to be staged and opened again (claude-config#559). Now the
  # word is reported once, and the reviewer fixes it and saves again.
  printf 'waiting for APPROVED or ABORT (timeout %ss)...\n' "${POLL_TIMEOUT}" >&2
  local reported=""
  CLASS=PENDING
  CLASS_WHY=""
  while ((waited < POLL_TIMEOUT)); do
    sleep 2
    waited=$((waited + 2))
    status="$(_status "${batch}")"
    _classify "${status}"
    [[ "${CLASS}" == "APPROVED" || "${CLASS}" == "ABORT" ]] && break
    if [[ "${CLASS}" == "UNRECOGNIZED" && "${status}" != "${reported}" ]]; then
      printf "gate-review: read STATUS '%s'; not understood (%s). Nothing approved. Still waiting: fix the word and save again.\n" \
        "${status}" "${CLASS_WHY}" >&2
      reported="${status}"
    fi
  done

  case "${CLASS}" in
    APPROVED) ;;
    ABORT)
      # ABORT means "not approved", not "discard my text": this batch's
      # approvals go, the buffer stays. Only this batch's items: wiping all
      # of approved/ silently revoked an unrelated approval (a PR body
      # approved an hour earlier, or another session's), the same failure
      # _split_batch already avoids (claude-config#613). Older approvals
      # still expire after APPROVAL_TTL.
      local item
      for item in "${batch_items[@]}"; do
        rm -f "${APPROVED:?}/${item}"
      done
      _die "ABORT (STATUS read as '${status}'); nothing approved"
      ;;
    PENDING)
      _die "still PENDING after ${POLL_TIMEOUT}s; nothing approved"
      ;;
    *)
      _die "unrecognized status '${status}' after ${POLL_TIMEOUT}s (${CLASS_WHY}); nothing approved"
      ;;
  esac

  _split_batch "${batch}" "${nonce}"
  # Only this batch's own file, and only once its text is in approved/. Every
  # other exit leaves it for the next open to carry forward; its nonce is
  # never reused, so it cannot be split as approved by another run.
  rm -f "${batch}"
  KEPT_BATCH=""
  # The word actually read, so a fuzzy accept is visible rather than silent.
  # The count is this key's approved/ only; other keys' approvals are not
  # this batch's business.
  local approved_count item
  approved_count="$(find "${APPROVED}" -type f | wc -l | tr -d ' ')"
  printf "approved %s item(s) (STATUS read as '%s'%s)\n" \
    "${approved_count}" "${status}" "${CLASS_WHY:+; ${CLASS_WHY}}"
  # The approved copies now sit under this key, so give the exact paths to
  # commit or post from rather than leave the caller to build them.
  for item in "${batch_items[@]}"; do
    [[ -f "${APPROVED}/${item}" ]] && printf 'approved: %s\n' "${APPROVED}/${item}"
  done
  return 0
}

# Optimal-string-alignment distance: Levenshtein plus one edit for swapping
# two adjacent letters. That swap is the common typo (APPORVED, APPROVDE), and
# counting it as one edit lets the approve threshold stay at 1, which plain
# Levenshtein could not: it scores the swap as 2, and at 2 it also accepts
# UNAPPROVED, which is two insertions from APPROVED.
_edit_distance() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = length(a); m = length(b)
    for (i = 0; i <= n; i++) d[i, 0] = i
    for (j = 0; j <= m; j++) d[0, j] = j
    for (i = 1; i <= n; i++) {
      for (j = 1; j <= m; j++) {
        cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
        v = d[i - 1, j] + 1
        if (d[i, j - 1] + 1 < v) v = d[i, j - 1] + 1
        if (d[i - 1, j - 1] + cost < v) v = d[i - 1, j - 1] + cost
        if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j - 1, 1) &&
            substr(a, i - 1, 1) == substr(b, j, 1) && d[i - 2, j - 2] + 1 < v)
          v = d[i - 2, j - 2] + 1
        d[i, j] = v
      }
    }
    print d[n, m]
  }'
}

# Map a raw STATUS word to exactly one of APPROVED, ABORT, PENDING, or
# UNRECOGNIZED. Sets CLASS, and CLASS_WHY to a reason fit for the terminal.
#
# A false approve is the expensive direction, so every rule here leans toward
# UNRECOGNIZED, which approves nothing and keeps the batch waiting:
#   - Only trailing . and ! are dropped. Anything else that is not a letter --
#     a space, a second word, a ? -- makes the word unrecognized, so
#     "APPROVED?", "NOT APPROVED" and "APPROVED - BUT" never approve.
#   - A word with a negating prefix never approves, whatever its distance.
#   - A near-miss counts only at distance 1 (one wrong, missing, extra, or
#     swapped letter). Distance 2 or more is unrecognized.
#   - A near-miss that is also within 2 of another keyword is ambiguous, and
#     unrecognized. The keywords are far enough apart that no distance-1 word
#     trips this today; it is here so a future keyword cannot make it happen.
_classify() {
  local raw="$1" word kw d best="" best_d=99 near=0
  CLASS=UNRECOGNIZED
  CLASS_WHY=""
  word="${raw}"
  while [[ "${word}" == *[.!] ]]; do word="${word%?}"; done
  if [[ -z "${word}" ]]; then
    CLASS_WHY="empty status word"
    return 0
  fi
  if [[ ! "${word}" =~ ^[A-Z]+$ ]]; then
    CLASS_WHY="only letters, optionally followed by . or !, can match"
    return 0
  fi
  if ((${#word} > 12)); then
    CLASS_WHY="too long to be APPROVED, ABORT, or PENDING"
    return 0
  fi
  case "${word}" in
    APPROVED | ABORT | PENDING)
      CLASS="${word}"
      [[ "${word}" == "${raw}" ]] || CLASS_WHY="trailing punctuation ignored"
      return 0
      ;;
    UN* | DIS* | NO* | DE*)
      CLASS_WHY="negating prefix; never read as a keyword"
      return 0
      ;;
    *) ;;
  esac
  for kw in APPROVED ABORT PENDING; do
    d="$(_edit_distance "${word}" "${kw}")"
    ((d <= 2)) && near=$((near + 1))
    if ((d < best_d)); then
      best_d="${d}"
      best="${kw}"
    fi
  done
  if ((best_d > 1)); then
    CLASS_WHY="${best_d} edits from ${best}; only 1 is accepted"
    return 0
  fi
  if ((near > 1)); then
    CLASS_WHY="close to more than one of APPROVED, ABORT, PENDING"
    return 0
  fi
  CLASS="${best}"
  CLASS_WHY="1 edit from ${best}"
}

# The status word, or PENDING if the line is missing or unreadable: an
# unparseable buffer must not read as approval.
_status() {
  local line
  line="$(grep -m1 -E '^#[[:space:]]*STATUS:' "$1" 2>/dev/null || true)"
  [[ -n "${line}" ]] || { printf 'PENDING\n'; return 0; }
  printf '%s\n' "${line}" |
    sed -E 's/^#[[:space:]]*STATUS:[[:space:]]*//; s/[[:space:]]*$//' |
    tr '[:lower:]' '[:upper:]'
}

# Refuse to open while another gate-review is polling this same GATE_DIR.
_refuse_if_open() {
  local others
  others="$(pgrep -f 'gate-review(\.sh)? open' | grep -v "^$$\$" || true)"
  [[ -z "${others}" ]] && return 0
  {
    echo "gate-review: another review is already open (pid(s): ${others//$'\n'/ })."
    echo "gate-review: two reviews sharing one batch approve each other's text."
    echo "gate-review: finish or kill that one first."
  } >&2
  exit 1
}

# Split the saved buffer back into per-artifact approvals, so each commit is
# checked against its own text rather than the batch as a whole.
_split_batch() {
  local batch="$1" want_nonce="${2:-}" name="" body="" got_nonce
  # Only split the buffer this process wrote. Without this, a concurrent or
  # stale run splits whatever it finds and reports it approved.
  if [[ -n "${want_nonce}" ]]; then
    got_nonce="$(sed -n -E 's/^#[[:space:]]*BATCH:[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "${batch}" | head -1)"
    [[ "${got_nonce}" == "${want_nonce}" ]] ||
      _die "batch id mismatch (saw '${got_nonce}', expected '${want_nonce}'); nothing approved"
  fi

  # Deliberately NOT `rm -f approved/*` here. Clearing the whole directory made
  # each batch silently revoke the last one: approve a PR body now and a commit
  # message an hour later, and the PR body's approval was gone by push time,
  # with nothing to show it had ever been granted. Each name is instead cleared
  # by _write_approved as it is rewritten, so a batch revokes only what it
  # restates, and anything older than APPROVAL_TTL expires on its own. ABORT
  # follows the same rule: it revokes only the aborted batch's own items.

  # `|| [[ -n "${line}" ]]` catches a final line with no trailing newline.
  # Without it `read` returns false on that last line and the loop discards it,
  # so an editor saving without a trailing newline silently truncated the
  # approved body -- the bytes that would commit were not the bytes he read.
  # Measured 2026-09-18: a two-line body came back as one line.
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      '=== '*' ===')
        [[ -n "${name}" ]] && _write_approved "${name}" "${body}"
        name="${line#=== }"
        name="${name% ===}"
        body=""
        ;;
      # Strip `#` lines only in the framing header, before the first artifact.
      # Inside a body they are content: a markdown heading, a shebang, a
      # `Closes #N` trailer. Stripping those silently rewrote the approved
      # bytes, so `check` then failed against text that WAS approved.
      '#'*) [[ -z "${name}" ]] || body+="${line}"$'\n' ;;
      *) [[ -n "${name}" ]] && body+="${line}"$'\n' ;;
    esac
  done <"${batch}"
  [[ -n "${name}" ]] && _write_approved "${name}" "${body}"
  return 0
}

_write_approved() {
  local name="$1" body="$2" trimmed
  # Clear this name's prior approval BEFORE deciding whether to write a new
  # one. Emptying an item in the editor is how a reviewer drops it from the
  # set, so it must revoke; returning early without this rm would leave the
  # previous approval standing and read as "still approved".
  rm -f "${APPROVED:?}/${name}"
  # An item emptied in the editor is a deliberate abort, not an approval.
  trimmed="$(printf '%s' "${body}" | sed -e '/^[[:space:]]*$/d')"
  [[ -n "${trimmed}" ]] || return 0
  printf '%s' "${body}" >"${APPROVED}/${name}"
  _remove_pending "${PENDING}" "${name}"
}

# Age comes from mtime, not a TIMESTAMP line as in merge-lock: the approved
# file IS the hashed body, so any line added to it would break `check`.
# A file whose mtime cannot be read is left alone rather than guessed at.
#
# Both depths: approved/<key>/<name>, and the old flat approved/<name>. An
# approval written before the per-repo layout was a human's approval too; it
# still verifies and still expires on the same clock, so an upgrade neither
# drops nor extends it. A key directory fails the -f test and is skipped.
_prune_expired() {
  local now approval mtime
  now="$(date +%s)"
  for approval in "${APPROVED_ROOT}"/* "${APPROVED_ROOT}"/*/*; do
    [[ -f "${approval}" ]] || continue
    # GNU first: GNU `stat -f %m` fails but still prints filesystem info to stdout.
    mtime="$(stat -c %Y "${approval}" 2>/dev/null || stat -f %m "${approval}" 2>/dev/null)" || continue
    if ((now - mtime > APPROVAL_TTL)); then
      rm -f "${approval}"
    fi
  done
  return 0
}

# _route_line <repo> <dir>: one router call. check, measure and route share it, so they cannot disagree.
_route_line() {
  local -a route_args=()
  [[ -z "$1" ]] || route_args+=(--repo "$1")
  [[ -z "$2" ]] || route_args+=(--dir "$2")
  "${ROUTE_SCRIPT}" "${route_args[@]}"
}

# route [--repo R] [--dir D]: the route alone, no text (#698). No flag: visual / rule 3, as in check.
_cmd_route() {
  local repo="" dir="" flagged=0
  while (($# > 0)); do
    case "$1" in
      --repo)
        (($# >= 2)) || _die "route: --repo needs a value"
        repo="$2"
        flagged=1
        shift 2
        ;;
      --dir)
        (($# >= 2)) || _die "route: --dir needs a value"
        dir="$2"
        flagged=1
        shift 2
        ;;
      *) _die "route: unexpected argument: $1" ;;
    esac
  done
  if ((flagged == 0)); then
    printf 'visual\t3\tdestination unresolved\n'
    return 0
  fi
  _route_line "${repo}" "${dir}" || return 1
}

# Accept if the bytes match ANY approval. A match is not consumed: re-posting
# the same approved body (a `gh pr edit` after a `gh pr create`) is legitimate
# and must not require a second review of identical text, and consuming a match
# would block a retry after a transient push failure. What bounds the replay is
# age instead: an approval expires APPROVAL_TTL (30 minutes) after it was
# written, the same window merge-lock gives a lock.
_cmd_check() {
  local file="" repo="" dir="" kind="" flagged=0 want route outcome rule reason record line
  while (($# > 0)); do
    case "$1" in
      --kind)
        (($# >= 2)) || _die "check: --kind needs a value"
        kind="$2"
        _valid_kind "${kind}" || _die "check: unknown --kind '${kind}'; one of: ${LENGTH_KINDS}"
        shift 2
        ;;
      --repo)
        (($# >= 2)) || _die "check: --repo needs a value"
        repo="$2"
        flagged=1
        shift 2
        ;;
      --dir)
        (($# >= 2)) || _die "check: --dir needs a value"
        dir="$2"
        flagged=1
        shift 2
        ;;
      *)
        [[ -z "${file}" ]] || _die "check: unexpected argument: $1"
        file="$1"
        shift
        ;;
    esac
  done
  [[ -n "${file}" ]] || _die "check: no file given"
  _prune_expired
  [[ -f "${file}" ]] || return 1
  # Route by destination. With neither flag the destination is unresolved:
  # rule 3 (visual), no record needed, and no router call at all, so neither the
  # caller's cwd nor the rules file can change what existing callers see.
  # This path hardcodes visual / rule 3 and never reads the rules file, so a
  # future edit that makes the catch-all `* pangram` will NOT reach callers
  # that pass no destination (gh-wrapper.sh until it passes one). Change this
  # when the wrapper does.
  if ((flagged == 0)); then
    outcome="visual"
    rule=3
  else
    # The router's own stderr passes through: a rules error names its file
    # and line, and an unresolved repo or author is worth seeing.
    route="$(_route_line "${repo}" "${dir}")" || return 1
    IFS=$'\t' read -r outcome rule reason <<<"${route}"
  fi
  # exempt skips both the check and the visual review.
  [[ "${outcome}" == "exempt" ]] && return 0
  # Measured again as the kind the caller derived from the real command, not the kind it was staged as.
  if [[ -n "${kind}" ]]; then
    _length_check "${kind}" "${file}" || case $? in
      1)
        while IFS= read -r line; do
          [[ "${line}" == *' over by '* ]] && echo "gate-review: over length: ${line}" >&2
        done <<<"${LENGTH_OUT}"
        return 1
        ;;
      *)
        echo "gate-review: length checker error, not a verdict on the text: ${LENGTH_OUT}" >&2
        return 1
        ;;
    esac
  fi
  want="$(_hash "${file}")"
  # Every key, not only the caller's: the hook calls check from the Bash
  # tool's cwd, which for `git -C <repo> commit -F ...` is some other repo.
  # The key scopes what a reviewer is shown; the hash is what binds. Old flat
  # approvals count too, until they expire (see _prune_expired).
  local approval matched=0
  for approval in "${APPROVED_ROOT}"/* "${APPROVED_ROOT}"/*/*; do
    [[ -f "${approval}" ]] || continue
    [[ "$(_hash "${approval}")" == "${want}" ]] || continue
    matched=1
    break
  done
  if ((matched == 0)); then
    if [[ "${outcome}" == "pangram" ]]; then
      _check_fail_pangram "${file}" "${rule}"
    else
      echo "gate-review: rule ${rule} (${outcome}): no visual approval matches" >&2
    fi
    return 1
  fi
  # _record_path (defined above, near _verdict_line) keys on the raw bytes.
  record="$(_record_path "${file}")"
  if [[ "${outcome}" == "pangram" && ! -f "${record}" ]]; then
    echo "gate-review: rule ${rule} (pangram): no Pangram check ran on these bytes" >&2
    return 1
  fi
  return 0
}

# Pangram-gated and unapproved: say whether a check ran, so an unchecked text
# and a checked one that was never approved do not read the same.
_check_fail_pangram() {
  local file="$1" rule="$2" record verdict
  record="$(_record_path "${file}")"
  if [[ -f "${record}" ]]; then
    verdict="$(jq -er '.verdict // .status' "${record}" 2>/dev/null || echo unknown)"
    echo "gate-review: rule ${rule} (pangram): verdict ${verdict} recorded; no visual approval matches" >&2
  else
    echo "gate-review: rule ${rule} (pangram): no Pangram check ran on these bytes" >&2
  fi
}

# A real calendar date, checked in bash rather than by date(1): BSD `date -j -f`
# rolls 2026-02-31 over to 2026-03-03 with exit 0, and GNU `date -d` parses a
# different set of inputs. Plain arithmetic behaves the same on both.
_valid_date() {
  local d="$1" y m day max
  [[ "${d}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  y=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  day=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12)) || return 1
  case "${m}" in
    4 | 6 | 9 | 11) max=30 ;;
    2)
      if ((y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))); then
        max=29
      else
        max=28
      fi
      ;;
    *) max=31 ;;
  esac
  ((day >= 1 && day <= max))
}

# Time-boxed suspension of the whole gate. Andrew creates SUSPENDED by hand,
# containing one date (YYYY-MM-DD); the gate is off through the end of that
# local day and re-arms on its own the day after. Nothing here writes the file:
# both write hooks (Write/Edit and the Bash chain) keep agents out of GATE_DIR.
#
# Fails CLOSED. A missing, empty, unreadable, malformed, impossible (02-31) or
# past date means the gate stays armed. Only trailing whitespace is stripped,
# so a second line of content makes the file invalid rather than ignored.
#
# Active suspension is never silent: it prints one line to stderr each time a
# gated command is let through by it.
_cmd_suspended() {
  local file="${GATE_DIR}/SUSPENDED" content today
  [[ -f "${file}" && -r "${file}" ]] || return 1
  content="$(sed -e 's/[[:space:]]*$//' "${file}" 2>/dev/null)" || return 1
  _valid_date "${content}" || return 1
  today="$(date +%F)"
  [[ "${content}" < "${today}" ]] && return 1
  printf '[personify-gate] SUSPENDED until %s (%s)\n' "${content}" "${file}" >&2
  return 0
}

case "${1:-}" in
  stage) shift; _cmd_stage "$@" ;;
  open) _cmd_open ;;
  hash) shift; _hash "$1" ;;
  check) shift; _cmd_check "$@" ;;
  # The command that writes a check record for <file>; the Bash-tool hook
  # prints it when check blocks a Pangram-gated text for want of a record.
  hint) shift; _check_hint "${1:?usage: gate-review.sh hint <file>}" ;;
  measure) shift; _cmd_measure "$@" ;;
  route) shift; _cmd_route "$@" ;;
  personify-path) _personify_path ;;
  suspended) _cmd_suspended ;;
  *) _die "usage: gate-review.sh {stage --kind <kind> <name> <file>|open|hash <file>|check [--kind <kind>] <file> [--repo owner/name] [--dir path]|measure --kind <kind> [--title T] [--repo owner/name] [--dir path] <body|route [--repo owner/name] [--dir path]|hint <file>|personify-path|suspended}" ;;
esac
