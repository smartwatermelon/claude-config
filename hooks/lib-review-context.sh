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
# in flight" identity instead. Args: $1 = CHANGED_FILES (newline-separated).
round_history_key() {
  local changed_files="$1"
  local branch
  local hash
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
  hash=$(printf '%s\n%s\n' "${branch}" "$(printf '%s\n' "${changed_files}" | sort)" \
    | shasum -a 256 2>/dev/null | awk '{print $1}')
  printf '%s\n' "${hash:-noround}"
}

# Append a FAIL round's raw output to the history file, capped at the last
# 2 rounds (oldest dropped). Args: $1 = history file path, $2 = round output.
# Uses null-byte separation for safety (round_output cannot contain \0).
write_round_feedback() {
  local history_file="$1"
  local round_output="$2"

  local existing=""
  [[ -f "${history_file}" ]] && existing=$(cat "${history_file}")

  {
    if [[ -n "${existing}" ]]; then
      # Keep only the LAST round from what's already there (so appending
      # this one caps total retained rounds at 2). Use null-byte separator
      # for safety: review output cannot contain \0, eliminating injection risk.
      # Parse rounds via bash array expansion, not awk regex.
      local -a rounds
      IFS=$'\0' read -ra rounds <<<"${existing}"
      # If we have multiple rounds, print only the last one (index [-1]).
      if [[ ${#rounds[@]} -gt 1 ]]; then
        printf '%s\0' "${rounds[-1]}"
      fi
    fi
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
