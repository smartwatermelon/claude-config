#!/usr/bin/env bash
# =========================================================
# lib-review-issues.sh — Shared non-blocking issue functions
# =========================================================
#
# Extracted from pre-merge-review.sh for reuse by run-review.sh
# and other callers that need to create tracking issues from
# Claude review output.
#
# FILING MODE (decided by repo + author, not by caller):
#   - Personal repos:                gh issue create (as always)
#   - beacon-biosignals, Andrew's own work:   private Apple Note
#   - beacon-biosignals, teammate's work:     aggregated PR comment
#
# REQUIRED CALLER VARIABLES:
#   REPO_OWNER  — GitHub repository owner (org or user)
#   REPO_NAME   — GitHub repository name
#   PR_NUMBER   — (optional) Pull request number; omit for non-PR contexts.
#                 Also doubles as the "is this Andrew's own work" signal:
#                 unset means a local commit-level review (always his own).
#   PR_TITLE    — (optional) Pull request title; omit for non-PR contexts
#
# REQUIRED CALLER FUNCTIONS:
#   log_success  — Log a success message (e.g., log_success "msg")
#   log_warn     — Log a warning message (e.g., log_warn "msg")
#
# SOURCE GUARD:
#   Safe to source multiple times; second source is a no-op.
#
# USAGE:
#   source ~/.claude/hooks/lib-review-issues.sh
#   create_nonblocking_issues "$claude_output"
#
# =========================================================

# Source guard — idempotent sourcing
[[ -n "${_LIB_REVIEW_ISSUES_LOADED:-}" ]] && return 0
_LIB_REVIEW_ISSUES_LOADED=1

# Check if file is security-critical based on path patterns.
is_security_critical() {
  local file="$1"
  echo "${file}" | grep -qE '(auth|oauth|jwt|password|session|login|register|payment|billing|stripe|paypal|checkout|transaction|db|database|model|migration|schema|security|crypto|encryption|secret|vault)'
}

# Corporate-org gate. Hardcoded single org for now; generalize to a
# list/heuristic only if a second corporate org actually shows up.
is_corporate_repo() {
  [[ "${REPO_OWNER:-}" == "beacon-biosignals" ]]
}

# Memoized authenticated gh login, cached for the lifetime of this shell
# process. A failed lookup leaves the cache empty so a later successful call
# isn't blocked by an earlier one — but a successful lookup is never
# invalidated, so switching gh accounts mid-process (e.g. `gh auth switch`)
# won't be picked up. Not a concern in a hook process, which only lives for
# one commit/merge.
_GH_LOGIN_CACHE=""
_cached_gh_login() {
  if [[ -z "${_GH_LOGIN_CACHE:-}" ]]; then
    _GH_LOGIN_CACHE=$(command gh api user -q .login 2>/dev/null) || return 1
    [[ -n "${_GH_LOGIN_CACHE:-}" ]] || return 1
  fi
  echo "${_GH_LOGIN_CACHE}"
}

# Is the code under review Andrew's own? True when there's no PR_NUMBER
# (commit-level review — always a local commit he's about to push).
# Otherwise compares the PR author to the authenticated gh login.
# Fails toward "not self" on any lookup error — the safest of the three
# filing modes (visible only in-PR-context, no public issue, no silent drop).
is_self_authored() {
  [[ -z "${PR_NUMBER:-}" ]] && return 0

  local pr_author
  pr_author=$(command gh pr view "${PR_NUMBER}" --repo "${REPO_OWNER}/${REPO_NAME}" --json author -q .author.login 2>/dev/null) || return 1
  [[ -n "${pr_author}" ]] || return 1

  local my_login
  my_login=$(_cached_gh_login) || return 1

  [[ "${pr_author}" == "${my_login}" ]]
}

# Parse NON_BLOCKING_ISSUE blocks from Claude's analysis output.
# Prints each block as a record separated by "---ISSUE---" sentinel.
# Returns empty string if no blocks found or if verdict is BLOCK_MERGE.
parse_nonblocking_issues() {
  local analysis_text="$1"

  # Don't parse non-blocking issues on a blocked merge
  if echo "${analysis_text}" | grep -qE "^VERDICT: BLOCK_MERGE"; then
    return 0
  fi

  # Extract each NON_BLOCKING_ISSUE...END_ISSUE block
  echo "${analysis_text}" | awk '
    /^NON_BLOCKING_ISSUE:$/ { in_block=1; block=""; next }
    /^END_ISSUE$/ {
      if (in_block) { print block; print "---ISSUE---"; in_block=0 }
      next
    }
    in_block { block = block $0 "\n" }
  '
}

# Build rich GitHub issue body.
# Args: title source location details
# If PR_NUMBER is set, includes PR reference line.
# If PR_NUMBER is unset/empty, uses SOURCE field value as context.
build_issue_body() {
  local title="$1"
  local source="$2"
  local location="$3"
  local details="$4"
  local merge_date
  merge_date=$(date +%Y-%m-%d)

  echo "## Non-Blocking Review Concern: ${title}"
  echo ""
  echo "**Source:** ${source}"
  echo "**Location:** \`${location}\`"

  if [[ -n "${PR_NUMBER:-}" ]]; then
    local pr_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PR_NUMBER}"
    echo "**PR:** #${PR_NUMBER} — ${PR_TITLE:-} (${pr_url})"
  fi

  echo "**Date:** ${merge_date}"
  echo ""
  echo "## What was flagged"
  echo ""
  echo "${details}"
  echo ""
  echo "## Context"
  echo ""

  if [[ -n "${PR_NUMBER:-}" ]]; then
    echo "This issue was automatically created from a non-blocking concern identified"
    echo "during pre-merge review of PR #${PR_NUMBER}. It was safe to merge but worth tracking."
  else
    echo "This issue was automatically created from a non-blocking concern identified"
    echo "during ${source}. It was flagged for tracking."
  fi

  echo ""
  echo "---"
  echo "*Created by lib-review-issues.sh*"
}

# Check if a location path requires the 'security' label.
needs_security_label() {
  local location="$1"
  # Strip line number suffix (e.g. "src/auth/jwt.ts:42" -> "src/auth/jwt.ts")
  local path_only="${location%%:*}"
  is_security_critical "${path_only}"
}

# Extract TITLE/SOURCE/LOCATION/DETAILS fields from a single issue block.
# Writes results into the four nameref args (caller-declared local vars).
_parse_issue_fields() {
  local block="$1"
  local -n _pif_title="$2"
  local -n _pif_source="$3"
  local -n _pif_location="$4"
  local -n _pif_details="$5"

  _pif_title=$(echo "${block}" | { grep "^TITLE:" || true; } | { head -1 || true; } | sed 's/^TITLE: //')
  _pif_source=$(echo "${block}" | { grep "^SOURCE:" || true; } | { head -1 || true; } | sed 's/^SOURCE: //')
  _pif_location=$(echo "${block}" | { grep "^LOCATION:" || true; } | { head -1 || true; } | sed 's/^LOCATION: //')
  # DETAILS may span multiple lines -- grab everything after the DETAILS: line
  _pif_details=$(echo "${block}" | { awk '/^DETAILS:/{found=1; sub(/^DETAILS: /,""); print; next} found{print}' || true; } | { sed '/^[[:space:]]*$/d' || true; })
}

# Write an issue body to the local pending-issues fallback dir.
# Prints the path of the file it wrote. Returns 1 (printing nothing) if the
# directory or file couldn't be written, so callers can fail loudly instead
# of logging a "Saved to: " message with an empty path.
_write_pending_issue_file() {
  local title="$1"
  local body="$2"
  local pending_dir="$3"

  mkdir -p "${pending_dir}" || return 1
  local slug
  slug=$(echo "${title}" | { tr '[:upper:]' '[:lower:]' || true; } | { tr -cs 'a-z0-9' '-' || true; } | { sed 's/-*$//' || true; } | cut -c1-40)
  # Use PR_NUMBER in filename when available, otherwise use date-based prefix
  local file_prefix="${PR_NUMBER:-$(date +%Y%m%d)}"
  local fallback_file="${pending_dir}/${file_prefix}-${slug}.md"
  local slug_index=1
  while [[ -f "${fallback_file}" ]]; do
    slug_index=$((slug_index + 1))
    fallback_file="${pending_dir}/${file_prefix}-${slug}-${slug_index}.md"
  done
  printf "%s\n" "${body}" >"${fallback_file}" || return 1
  echo "${fallback_file}"
}

# Escape a string for embedding in an AppleScript double-quoted literal that
# is itself interpolated into an unquoted bash heredoc (create_apple_note_issue).
# Two escaping layers are needed, in order:
#   1. AppleScript string syntax: backslash and double-quote.
#   2. Bash's unquoted-heredoc expansion: backslash-escape $ and ` too, so
#      review-agent-supplied content (TITLE/DETAILS) can't trigger command
#      substitution when bash reads the heredoc body before osascript sees it.
_escape_for_applescript() {
  printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g; s/\\\$/\\\\\$/g; s/\`/\\\\\`/g"
}

# Create a private note in the Notes.app "Tech Debt" folder via osascript.
# Returns 1 (without touching Notes.app) when osascript is unavailable,
# e.g. on Linux, so the caller can fall back.
# CONSTRAINT: the test helper `_load_fn` extracts this function by scanning
# for a line matching /^}$/ (see tests/test_pre_merge_nonblocking.bats). Keep
# every AppleScript "end ..." line indented — an unindented bare `}` inside
# the heredoc would truncate the extraction in tests.
create_apple_note_issue() {
  local title="$1"
  local body="$2"

  command -v osascript >/dev/null 2>&1 || return 1

  local escaped_title escaped_body body_html
  # AppleScript string literals can't span lines, so the title (unlike the
  # body, which converts newlines to <br>) must not contain any.
  escaped_title=$(_escape_for_applescript "${title}")
  escaped_title="${escaped_title//$'\n'/ }"
  escaped_body=$(_escape_for_applescript "${body}")
  body_html="${escaped_body//$'\n'/<br>}"

  osascript <<EOF
tell application "Notes"
  if not (exists folder "Tech Debt") then
    make new folder with properties {name:"Tech Debt"}
  end if
  tell folder "Tech Debt"
    make new note with properties {body:"<h1>${escaped_title}</h1>${body_html}"}
  end tell
end tell
EOF
}

# Parse a single issue block and file it as a private Apple Note.
# Falls back to the pending_dir local file when osascript is unavailable
# or fails — never falls back to a public gh issue create for corporate repos.
_process_issue_block_apple_note() {
  local block="$1"
  local pending_dir="$2"

  [[ -n "${block}" ]] || return 0

  local title source location details
  _parse_issue_fields "${block}" title source location details
  [[ -n "${title}" ]] || return 0

  local hashtags="#tech-debt #${REPO_NAME}"
  if needs_security_label "${location}"; then
    hashtags="${hashtags} #security"
  fi

  local body
  body=$(build_issue_body "${title}" "${source}" "${location}" "${details}")
  body="${body}"$'\n\n'"${hashtags}"

  if create_apple_note_issue "${title}" "${body}"; then
    log_success "Filed private tech-debt note: ${title}"
    log_success "  -> Notes.app / Tech Debt folder (${hashtags})"
  else
    log_warn "Could not create Apple Note automatically (osascript unavailable or failed)."
    local fallback_file
    if fallback_file=$(_write_pending_issue_file "${title}" "${body}" "${pending_dir}"); then
      log_warn "  Saved to: ${fallback_file}"
      log_warn "  File this privately (e.g. paste into Notes.app 'Tech Debt' folder) — do not create a public GitHub issue for this."
    else
      log_warn "  Could not write fallback file either (${pending_dir}) — this finding is lost: ${title}"
    fi
  fi
}

# Format a single issue block as a markdown bullet for the aggregated PR comment.
_format_issue_bullet() {
  local block="$1"
  [[ -n "${block}" ]] || return 0

  local title source location details
  _parse_issue_fields "${block}" title source location details
  [[ -n "${title}" ]] || return 0

  # DETAILS may span multiple lines; collapse to one line so it stays a
  # single markdown bullet instead of trailing lines reading as loose text.
  details="${details//$'\n'/ }"

  printf -- "- **%s** (%s, \`%s\`): %s\n" "${title}" "${source}" "${location}" "${details}"
}

# Post all parsed issue blocks as a single aggregated PR comment. Used for
# beacon-biosignals PRs that aren't the reviewer's own work — visible to that
# PR's participants only, not announced org-wide, and not attributed to a
# public GitHub issue. Falls back to per-issue pending files (same as the
# other two filing paths) if the comment can't be posted, so a `gh` failure
# never silently drops a finding.
post_nonblocking_as_pr_comment() {
  local parsed="$1"
  local pending_dir="$2"

  if [[ -z "${PR_NUMBER:-}" ]]; then
    log_warn "Skipping PR-comment filing: no PR_NUMBER in context"
    return 0
  fi

  local comment_body="### Non-blocking review notes"$'\n\n'"Filed as a comment rather than a tracking issue, since this is a peer PR review."$'\n'
  local current_block="" bullet
  while IFS= read -r line; do
    if [[ "${line}" == "---ISSUE---" ]]; then
      bullet=$(_format_issue_bullet "${current_block}")
      [[ -n "${bullet}" ]] && comment_body+="${bullet}"$'\n'
      current_block=""
    else
      current_block+="${line}"$'\n'
    fi
  done <<<"${parsed}"
  bullet=$(_format_issue_bullet "${current_block}")
  [[ -n "${bullet}" ]] && comment_body+="${bullet}"$'\n'

  if command gh pr comment "${PR_NUMBER}" --repo "${REPO_OWNER}/${REPO_NAME}" --body "${comment_body}" >/dev/null 2>&1; then
    log_success "Posted non-blocking review notes as a PR comment on #${PR_NUMBER}"
    return 0
  fi

  log_warn "Could not post non-blocking review notes as a PR comment on #${PR_NUMBER}"
  local fallback_file
  if fallback_file=$(_write_pending_issue_file "pr-${PR_NUMBER}-nonblocking-notes" "${comment_body}" "${pending_dir}"); then
    log_warn "  Saved to: ${fallback_file}"
    log_warn "  Paste this into a comment on PR #${PR_NUMBER} manually."
  else
    log_warn "  Could not write fallback file either (${pending_dir}) — these findings are lost for PR #${PR_NUMBER}"
  fi
}

# Create GitHub issues from parsed NON_BLOCKING_ISSUE blocks.
# Best-effort: failures write a fallback file and print a warning.
# Filing mode depends on repo + authorship — see file header.
# Args: analysis_text (full Claude output)
create_nonblocking_issues() {
  local analysis_text="$1"
  local pending_dir="${PENDING_ISSUES_DIR:-${HOME}/.claude/pending-issues}"

  # Guard: repo info required for gh issue create and fallback URL
  if [[ -z "${REPO_OWNER:-}" || -z "${REPO_NAME:-}" ]]; then
    log_warn "Skipping non-blocking issue creation: repo info unavailable"
    return 0
  fi

  local parsed
  parsed=$(parse_nonblocking_issues "${analysis_text}")
  [[ -n "${parsed}" ]] || return 0

  if is_corporate_repo && ! is_self_authored; then
    post_nonblocking_as_pr_comment "${parsed}" "${pending_dir}"
    return 0
  fi

  if ! is_corporate_repo; then
    # Ensure labels exist (idempotent) — only needed for the gh-issue path.
    command gh label create "tech-debt" --color "#e4e669" --description "Technical debt to address" --repo "${REPO_OWNER}/${REPO_NAME}" --force >/dev/null 2>&1 || true
    command gh label create "security" --color "#d93f0b" --description "Security-related concern" --repo "${REPO_OWNER}/${REPO_NAME}" --force >/dev/null 2>&1 || true
  fi

  # Process each block (separated by ---ISSUE--- sentinel).
  local current_block=""
  while IFS= read -r line; do
    if [[ "${line}" == "---ISSUE---" ]]; then
      if is_corporate_repo; then
        _process_issue_block_apple_note "${current_block}" "${pending_dir}"
      else
        _process_issue_block "${current_block}" "${pending_dir}"
      fi
      current_block=""
    else
      current_block+="${line}"$'\n'
    fi
  done <<<"${parsed}"
  if is_corporate_repo; then
    _process_issue_block_apple_note "${current_block}" "${pending_dir}"
  else
    _process_issue_block "${current_block}" "${pending_dir}"
  fi
}

# Parse a single issue block and create the GH issue (or fallback file).
_process_issue_block() {
  local block="$1"
  local pending_dir="$2"

  [[ -n "${block}" ]] || return 0

  local title source location details
  _parse_issue_fields "${block}" title source location details

  [[ -n "${title}" ]] || return 0

  # Determine labels
  local labels="tech-debt"
  if needs_security_label "${location}"; then
    labels="tech-debt,security"
  fi

  # Build issue body
  local body
  body=$(build_issue_body "${title}" "${source}" "${location}" "${details}")

  # Attempt to create GitHub issue.
  # Use a temp file for stderr so gh warnings/upgrade notices don't contaminate
  # issue_url (same pattern as _fetch_pr_json).
  local issue_url gh_stderr_file
  gh_stderr_file=$(mktemp)
  if issue_url=$(command gh issue create \
    --repo "${REPO_OWNER}/${REPO_NAME}" \
    --title "${title}" \
    --body "${body}" \
    --label "${labels}" 2>"${gh_stderr_file}"); then
    rm -f "${gh_stderr_file}"
    log_success "Created tracking issue: ${title}"
    log_success "  -> ${issue_url}"
  else
    local gh_err
    gh_err=$(cat "${gh_stderr_file}")
    rm -f "${gh_stderr_file}"
    [[ -n "${gh_err}" ]] && log_warn "  gh error: ${gh_err}"
    # Fallback: write to file
    log_warn "Could not create GitHub issue automatically."
    local fallback_file
    if fallback_file=$(_write_pending_issue_file "${title}" "${body}" "${pending_dir}"); then
      log_warn "  Saved to: ${fallback_file}"
      log_warn "  Run: gh issue create --repo ${REPO_OWNER}/${REPO_NAME} --title \"${title}\" --body-file ${fallback_file} --label \"${labels}\""
    else
      log_warn "  Could not write fallback file either (${pending_dir}) — this finding is lost: ${title}"
    fi
  fi
}
