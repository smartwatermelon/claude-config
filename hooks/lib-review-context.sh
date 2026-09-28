#!/usr/bin/env bash
# =========================================================
# lib-review-context.sh — Shared review-prompt context helpers
# =========================================================
#
# Extracted from run-review.sh so file-scope-context extraction and
# round-over-round feedback tracking can be unit tested independently
# of the full hook script.
#
# SOURCE GUARD:
#   Safe to source multiple times; second source is a no-op.
#
# USAGE:
#   source ~/.claude/hooks/lib-review-context.sh
#   extract_file_header_context "path/to/file.sh"
#
# =========================================================

[[ -n "${_LIB_REVIEW_CONTEXT_LOADED:-}" ]] && return 0
_LIB_REVIEW_CONTEXT_LOADED=1

# Reads a file's leading comment block (shebang line excluded) so review
# prompts can see stated scope/intent (e.g. "macOS-only, not intended for
# Linux/CI") that may not appear in the diff hunk itself. Reads from the
# working tree, not git blob — pre-commit review runs against files that
# already exist on disk with the staged changes applied to the index but
# also present as regular files (this is always true for a normal `git
# commit` invocation; the hook never runs against a bare/detached tree).
#
# Args: $1 = file path (relative to repo root or absolute)
#       $2 = max lines to extract (default 15)
# Echoes: the leading comment block, one line per output line, with the
#         leading '#' and exactly one following space stripped. Empty
#         output (no lines) if the file doesn't exist, is not readable,
#         or has no leading comment block.
extract_file_header_context() {
  local file="$1"
  local max_lines="${2:-15}"

  [[ -r "${file}" ]] || return 0

  awk -v max="${max_lines}" '
    NR == 1 && /^#!/ { next }               # skip shebang
    /^[[:space:]]*$/ { next }               # skip blank lines while still in header
    /^[[:space:]]*#/ {
      count++
      if (count > max) exit
      line = $0
      sub(/^[[:space:]]*#[[:space:]]?/, "", line)
      print line
      next
    }
    { exit }                                 # first non-comment, non-blank line ends header
  ' "${file}" 2>/dev/null || true
}

# Derive a stable cache key for round-over-round feedback tracking. Diff
# hashes change on every retry (the developer edits the code), so DIFF_HASH
# can't key this — key on the more stable "which branch, which files are
# in flight" identity instead.
#
# Args: $1 = the paths the REVIEWED DIFF touches, newline-separated. Callers
# pass the diff's own header paths (diff_changed_paths in run-review.sh), not
# the cwd repo's staged index (#622). A piped `--no-file` review from a clean
# checkout has an empty index, so the old index-based key was
# hash(branch + "") for every piped diff: unrelated diffs shared one memory
# slot, and one diff's findings were injected into another's review (#488).
# In a normal pre-commit run the diff IS `git diff --cached`, so a retry on
# the same files still gets the same key.
#
# An empty path list returns "noround" (no round memory). An empty list is
# exactly the shared slot described above, so no key is safer than one.
#
# The "round-key-v2" line salts the hash so no key computed here can equal a
# key from the old index-based scheme. A round-history file written before
# this change is therefore never read again; the cache's 30-day mtime sweep
# in run-review.sh removes it.
#
# Captures the hash before falling back, since a pipeline's exit status is
# the LAST command's (awk, which exits 0 even on empty stdin) — `|| echo`
# on the pipeline itself would never fire on a shasum failure.
round_history_key() {
  local reviewed_paths="$1"
  local branch hash sorted
  sorted=$(grep -v '^$' <<<"${reviewed_paths}" | sort -u || true)
  if [[ -z "${sorted}" ]]; then
    printf 'noround\n'
    return 0
  fi
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  # The `|| true` below satisfies SC2312 and changes nothing: the fallback
  # here is value-based (`${hash:-noround}`), not status-based, exactly as
  # the comment above describes.
  hash=$(printf 'round-key-v2\n%s\n%s\n' "${branch}" "${sorted}" \
    | { shasum -a 256 2>/dev/null || true; } | awk '{print $1}')
  printf '%s\n' "${hash:-noround}"
}

# Append a FAIL round's raw output to the history file, capped at the last
# 2 rounds (oldest dropped). Args: $1 = history file path, $2 = round output.
# NOTE: uses a plain "---ROUND---" line delimiter. CODE_REVIEWER_OUTPUT is
# Claude CLI text output, not untrusted/adversarial input this codebase
# defends against, so a literal-string collision is out of scope here.
#
# Rounds are collected into an explicitly INDEXED array (rounds[0] is the
# oldest round found on disk, rounds[-1] is the newest) so "keep the last
# N" is a plain array-slice operation, not something inferred from which
# scratch variable held what after a loop exits.
write_round_feedback() {
  local history_file="$1"
  local round_output="$2"

  local existing=""
  [[ -f "${history_file}" ]] && existing=$(cat "${history_file}")

  local -a rounds=()
  if [[ -n "${existing}" ]]; then
    local current=""
    while IFS= read -r line; do
      if [[ "${line}" == "---ROUND---" ]]; then
        rounds+=("${current}")
        current=""
      else
        current+="${line}"$'\n'
      fi
    done <<<"${existing}"
    # Trailing content after the last delimiter (or the whole file, if no
    # delimiter was ever seen) is one more round — always non-empty here
    # since write_round_feedback never writes a file ending in a bare
    # delimiter with nothing after it.
    rounds+=("${current}")
  fi

  # This round is about to be appended, so keep at most 1 prior round
  # (rounds[-1], the newest already on disk) — combined with the new
  # round below, that caps total retained rounds at 2. An empty element
  # (a history file that was all delimiters, no content) is discarded
  # rather than treated as a real round.
  local keep=""
  if [[ ${#rounds[@]} -ge 1 && -n "${rounds[-1]}" ]]; then
    keep="${rounds[-1]}"
  fi

  {
    [[ -n "${keep}" ]] && printf '%s---ROUND---\n' "${keep}"
    printf '%s\n' "${round_output}"
  } >"${history_file}.tmp" && mv "${history_file}.tmp" "${history_file}"
}

# Echo a history file's contents verbatim; empty string if missing.
read_round_feedback() {
  local history_file="$1"
  [[ -f "${history_file}" ]] && cat "${history_file}" || true
}

# Remove a round-history file (called on PASS to reset for future runs).
clear_round_feedback() {
  local history_file="$1"
  rm -f "${history_file}"
}

# --- Checking carried-forward findings against the real tree (#488) ---
#
# Round history is injected into the next review as PRIOR ROUND FEEDBACK.
# Nothing checked it, so a finding against a file that does not exist was
# handed to the next reviewer as established fact, and that reviewer
# re-raised it as BLOCKING. #488's `tally.sh` finding arrived this way: the
# blocking output says "Prior-round feedback flagged tally.sh:3".
#
# filter_prior_round_feedback checks each carried-forward ISSUE block before
# it reaches the prompt:
#   - Every concrete path its LOCATION names is missing from the reviewed diff,
#     the working tree, and the index: the block is DROPPED.
#   - A named file exists but none of the code the block quotes (a backtick
#     span of 6+ characters) appears in it: the block is kept and MARKED
#     stale. A developer who fixed the finding produces exactly this state,
#     and round memory exists to tell the next round that it was addressed.
#   - Anything else, including every case this cannot decide (no concrete
#     path, no repo, a git error): the block is kept unchanged. That is the
#     behavior before this check existed.
#
# SEVERITY is never read. The filter applies only to the PREVIOUS round's
# output, so the current round's own findings are untouched, and a real
# security finding raised fresh still blocks.
#
# A round whose ISSUE blocks were all dropped is omitted. A round with no
# ISSUE blocks (a bare "VERDICT: FAIL (timeout)") passes through unchanged.
#
# Args: $1 = round-history text (rounds separated by "---ROUND---")
#       $2 = repo top level (empty = cannot check; everything is kept)
#       $3 = newline-separated paths the current diff touches (may be empty)
#       $4 = log file for one "stale-prior-round:" line per dropped or marked
#            block (optional; empty = no log)
# Echoes: the filtered text. Empty when no round survives.

# Concrete file paths a LOCATION value names, one per line. Backticks,
# markdown emphasis, parentheticals, ":<line>" suffixes and a leading "./" are
# removed. A token counts as a path only if it contains "/" or ends in an
# extension, so "N/A", "general" and "multiple files" name nothing. A path
# under "~" is skipped, which keeps the block when it is the only path.
_prior_location_paths() {
  local loc="$1" tok
  local -a toks=()
  loc="${loc//\`/}"
  loc="${loc//\*/}"
  loc=$(sed -E 's/\([^)]*\)//g' <<<"${loc}" || true)
  read -ra toks <<<"${loc//[,;]/ }"
  for tok in "${toks[@]}"; do
    tok="${tok%%:*}"
    tok="${tok%.}"
    tok="${tok#./}"
    [[ -n "${tok}" ]] || continue
    [[ "${tok}" =~ ^[A-Za-z0-9._/@+~-]+$ ]] || continue
    [[ "${tok,,}" == "n/a" ]] && continue
    # A home-relative path is outside the repo, so this cannot check it.
    [[ "${tok}" == "~"* ]] && continue
    [[ "${tok}" == */* || "${tok}" =~ \.[A-Za-z0-9]+$ ]] || continue
    printf '%s\n' "${tok}"
  done
}

# Does path $1 exist for this review? A path the current diff names counts,
# exactly or by basename, even when it is not on disk (a diff piped in from
# another checkout). Otherwise the working tree and the index under top level
# $2 decide. Prints the on-disk file to use for the quote check, if any.
# Returns 0 = exists, 1 = missing, 2 = cannot tell (treated as exists).
_prior_path_status() {
  local path="$1" top="$2" reviewed="$3" base rp ls_out in_diff=0
  base="${path##*/}"
  if [[ -n "${reviewed}" ]]; then
    # diff_changed_paths lists each header path with and without its a/, b/
    # (or mnemonic i/, w/) prefix, so keep looking for the entry on disk.
    while IFS= read -r rp; do
      [[ -z "${rp}" ]] && continue
      if [[ "${rp}" == "${path}" || "${rp##*/}" == "${base}" ]]; then
        in_diff=1
        if [[ -n "${top}" && -f "${top}/${rp}" ]]; then
          printf '%s\n' "${top}/${rp}"
          return 0
        fi
      fi
    done <<<"${reviewed}"
  fi
  if [[ -z "${top}" || ! -d "${top}" ]]; then
    [[ "${in_diff}" -eq 1 ]] && return 0
    return 2
  fi
  if [[ "${path}" == /* ]]; then
    if [[ -e "${path}" ]]; then
      [[ -f "${path}" ]] && printf '%s\n' "${path}"
      return 0
    fi
    [[ "${in_diff}" -eq 1 ]] && return 0
    return 1
  fi
  if [[ -e "${top}/${path}" ]]; then
    [[ -f "${top}/${path}" ]] && printf '%s\n' "${top}/${path}"
    return 0
  fi
  # Reviewers often cite a basename ("collect.sh:152") for a file deeper in
  # the tree. --cached covers a staged add, --others an untracked file.
  if ! ls_out=$(git -C "${top}" ls-files --cached --others --exclude-standard \
    -- "${path}" "*/${path}" 2>/dev/null); then
    return 2
  fi
  if [[ -z "${ls_out}" ]]; then
    [[ "${in_diff}" -eq 1 ]] && return 0
    return 1
  fi
  rp=$(head -n 1 <<<"${ls_out}")
  [[ -f "${top}/${rp}" ]] && printf '%s\n' "${top}/${rp}"
  return 0
}

# Decide one ISSUE block. Echoes "keep", "drop <paths>" or "stale <paths>".
_prior_block_decision() {
  local block="$1" top="$2" reviewed="$3"
  local loc paths p status file span
  local -a files=() missing=() spans=()
  loc=$(grep -m 1 -iE '^[[:space:]*-]*LOCATION[*]*:' <<<"${block}" \
    | sed -E 's/^[[:space:]*-]*[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn][*]*:[[:space:]]*//' || true)
  paths=$(_prior_location_paths "${loc}")
  if [[ -z "${paths}" ]]; then
    printf 'keep\n'
    return 0
  fi
  local found=0
  while IFS= read -r p; do
    [[ -z "${p}" ]] && continue
    status=0
    file=$(_prior_path_status "${p}" "${top}" "${reviewed}") || status=$?
    if [[ "${status}" -eq 1 ]]; then
      missing+=("${p}")
    else
      found=1
      [[ -n "${file}" ]] && files+=("${file}")
    fi
  done <<<"${paths}"
  if [[ "${found}" -eq 0 ]]; then
    printf 'drop %s\n' "${missing[*]}"
    return 0
  fi
  # Quote check, only against files actually on disk.
  if [[ ${#files[@]} -gt 0 ]]; then
    # $'\x60' is a backtick, kept out of single quotes for SC2016.
    local bt=$'\x60'
    while IFS= read -r span; do
      span="${span#"${bt}"}"
      span="${span%"${bt}"}"
      [[ ${#span} -ge 6 ]] && spans+=("${span}")
    done < <(grep -oE "${bt}[^${bt}]+${bt}" <<<"${block}" || true)
    if [[ ${#spans[@]} -gt 0 ]]; then
      for span in "${spans[@]}"; do
        if grep -qF -- "${span}" "${files[@]}" 2>/dev/null; then
          printf 'keep\n'
          return 0
        fi
      done
      printf 'stale %s\n' "${files[*]#"${top}"/}"
      return 0
    fi
  fi
  printf 'keep\n'
}

filter_prior_round_feedback() {
  local feedback="$1" top="$2" reviewed="${3:-}" log="${4:-}"
  local -a rounds=()
  local current="" line
  [[ -n "${feedback}" ]] || return 0
  if [[ -z "${top}" ]]; then
    printf '%s\n' "${feedback}"
    return 0
  fi
  while IFS= read -r line; do
    if [[ "${line}" == "---ROUND---" ]]; then
      rounds+=("${current}")
      current=""
    else
      current+="${line}"$'\n'
    fi
  done <<<"${feedback}"
  rounds+=("${current}")

  local round out="" first=1
  for round in "${rounds[@]}"; do
    local hdr="" block="" kept="" had_issue=0 kept_issue=0 decision
    local -a blocks=()
    while IFS= read -r line; do
      if [[ "${line}" =~ ^[[:space:]*-]*ISSUE[*]*: ]]; then
        had_issue=1
        [[ -n "${block}" ]] && blocks+=("${block}")
        block="${line}"$'\n'
      elif [[ -n "${block}" ]]; then
        block+="${line}"$'\n'
      else
        hdr+="${line}"$'\n'
      fi
    done <<<"${round%$'\n'}"
    [[ -n "${block}" ]] && blocks+=("${block}")

    if [[ "${had_issue}" -eq 0 ]]; then
      [[ -n "${hdr//[[:space:]]/}" ]] || continue
      kept="${hdr}"
    else
      kept="${hdr}"
      for block in "${blocks[@]}"; do
        decision=$(_prior_block_decision "${block}" "${top}" "${reviewed}")
        case "${decision}" in
          drop\ *)
            [[ -n "${log}" ]] && printf 'stale-prior-round: dropped (no such file: %s)\n' "${decision#drop }" >>"${log}" 2>/dev/null || true
            ;;
          stale\ *)
            kept_issue=1
            [[ -n "${log}" ]] && printf 'stale-prior-round: marked (quoted code not found in %s)\n' "${decision#stale }" >>"${log}" 2>/dev/null || true
            kept+="[STALE: the code this finding quoted no longer appears in ${decision#stale }. It was probably addressed. Re-raise it only if the current diff still shows the problem.]"$'\n'"${block}"
            ;;
          *)
            kept_issue=1
            kept+="${block}"
            ;;
        esac
      done
      [[ "${kept_issue}" -eq 1 ]] || continue
    fi
    if [[ "${first}" -eq 1 ]]; then
      first=0
    else
      out+="---ROUND---"$'\n'
    fi
    out+="${kept}"
  done
  [[ -n "${out}" ]] && printf '%s' "${out}"
  return 0
}
