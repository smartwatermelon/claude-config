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
