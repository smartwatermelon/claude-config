#!/usr/bin/env bash
# =========================================================
# lib-review-issues.sh — Shared non-blocking issue functions
# =========================================================
#
# Extracted from pre-merge-review.sh for reuse by run-review.sh
# and other callers that need to create tracking issues from
# Claude review output.
#
# REQUIRED CALLER VARIABLES:
#   REPO_OWNER  — GitHub repository owner (org or user)
#   REPO_NAME   — GitHub repository name
#   PR_NUMBER   — (optional) Pull request number; omit for non-PR contexts
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

# Create GitHub issues from parsed NON_BLOCKING_ISSUE blocks.
# Best-effort: failures write a fallback file and print a warning.
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

  # Ensure labels exist (idempotent)
  command gh label create "tech-debt" --color "#e4e669" --description "Technical debt to address" --repo "${REPO_OWNER}/${REPO_NAME}" --force >/dev/null 2>&1 || true
  command gh label create "security" --color "#d93f0b" --description "Security-related concern" --repo "${REPO_OWNER}/${REPO_NAME}" --force >/dev/null 2>&1 || true

  # Process each block (separated by ---ISSUE--- sentinel).
  local current_block=""
  while IFS= read -r line; do
    if [[ "${line}" == "---ISSUE---" ]]; then
      _process_issue_block "${current_block}" "${pending_dir}"
      current_block=""
    else
      current_block+="${line}"$'\n'
    fi
  done <<<"${parsed}"
  _process_issue_block "${current_block}" "${pending_dir}"
}

# Parse a single issue block and create the GH issue (or fallback file).
_process_issue_block() {
  local block="$1"
  local pending_dir="$2"

  [[ -n "${block}" ]] || return 0

  # Extract fields from block
  local title source location details
  title=$(echo "${block}" | { grep "^TITLE:" || true; } | { head -1 || true; } | sed 's/^TITLE: //')
  source=$(echo "${block}" | { grep "^SOURCE:" || true; } | { head -1 || true; } | sed 's/^SOURCE: //')
  location=$(echo "${block}" | { grep "^LOCATION:" || true; } | { head -1 || true; } | sed 's/^LOCATION: //')
  # DETAILS may span multiple lines -- grab everything after the DETAILS: line
  details=$(echo "${block}" | { awk '/^DETAILS:/{found=1; sub(/^DETAILS: /,""); print; next} found{print}' || true; } | { sed '/^[[:space:]]*$/d' || true; })

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
    mkdir -p "${pending_dir}"
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
    printf "%s\n" "${body}" >"${fallback_file}"
    log_warn "Could not create GitHub issue automatically."
    log_warn "  Saved to: ${fallback_file}"
    log_warn "  Run: gh issue create --repo ${REPO_OWNER}/${REPO_NAME} --title \"${title}\" --body-file ${fallback_file} --label \"${labels}\""
  fi
}
