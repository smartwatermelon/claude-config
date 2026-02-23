#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# pre-merge-review.sh — Analyze PR reviews before merge
# =========================================================
#
# Called by gh() wrapper in functions.sh before `gh pr merge`
# Fetches PR review comments and analyzes for unresolved issues.
#
# USAGE:
#   Called automatically via gh wrapper, or directly:
#   ~/.claude/hooks/pre-merge-review.sh pr merge [PR_NUMBER] [flags]
#
# FEATURES:
#   - Filters out outdated and resolved inline comments
#   - Targeted diff extraction for large PRs:
#     * Small diffs (<= 1000 lines): Full diff included
#     * Large diffs (> 1000 lines): Extracts complete diff sections
#       for files with inline comments, summarizes others
#     * Ensures critical review context is always visible
#
# EXIT CODES:
#   0 = Review passed (safe to merge)
#   1 = Review failed (unresolved issues or error)
#
# =========================================================

# --- Configuration ---
CLAUDE_CLI="${CLAUDE_CLI:-${HOME}/.local/bin/claude}"
TIMEOUT_SECONDS=120

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Helpers ---
log_info() { echo -e "${BLUE}[pre-merge]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[pre-merge]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[pre-merge]${NC} $*" >&2; }
log_error() { echo -e "${RED}[pre-merge]${NC} $*" >&2; }

# --- File Classification Functions ---

# Classify file as data/config file
is_data_file() {
  local file="$1"
  # Match lock files, minified files, generated files, and JSON
  # Order specific patterns before wildcards to avoid redundancy
  case "${file}" in
    pnpm-lock.yaml | \
      *-lock.json | *.lock | \
      *.min.js | *.min.css | *.bundle.js | *.generated.* | \
      *.json)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Check if file is security-critical
is_security_critical() {
  local file="$1"
  echo "${file}" | grep -qE '(auth|oauth|jwt|password|session|login|register|payment|billing|stripe|paypal|checkout|transaction|db|database|model|migration|schema|security|crypto|encryption|secret|vault)'
}

# Check if file has active inline comments
has_inline_comments() {
  local file="$1"
  echo "${COMMENTED_FILES}" | grep -qF "${file}"
}

# Extract diff section for a specific file
extract_file_diff() {
  local full_diff="$1"
  local target_file="$2"

  echo "${full_diff}" | awk -v file="${target_file}" '
    BEGIN { in_target = 0 }
    /^diff --git/ {
      in_target = 0
      # Extract b/ path which handles spaces correctly (POSIX-compatible)
      # Format: "diff --git a/path b/path"
      idx = index($0, " b/")
      if (idx > 0) {
        file_path = substr($0, idx + 3)
      }
      if (file_path == file) {
        in_target = 1
        print $0
      }
      next
    }
    in_target { print }
  '
}

# Get list of changed files from diff
get_changed_files() {
  local diff="$1"
  # Extract b/ path which handles spaces correctly
  echo "${diff}" | grep -E '^diff --git' | sed -E 's/^diff --git a\/.* b\/(.+)$/\1/'
}

# --- Diff Summarization Functions ---

# Summarize data file when CI passed
summarize_data_file() {
  local file_path="$1"
  local file_diff="$2"

  local added
  local removed
  added=$(echo "${file_diff}" | grep -c '^+[^+]' || echo "0")
  removed=$(echo "${file_diff}" | grep -c '^-[^-]' || echo "0")

  echo "diff --git a/${file_path} b/${file_path}"
  echo "--- CI validated data file (not shown) ---"
  echo "File: ${file_path}"
  echo "Changes: +${added} -${removed} lines"
  echo ""
}

# Truncate code file diff (first/last 50 lines)
truncate_code_diff() {
  local file_diff="$1"
  local total_lines
  total_lines=$(echo "${file_diff}" | wc -l)

  if [[ ${total_lines} -le 100 ]]; then
    echo "${file_diff}"
  else
    local header
    local footer
    local truncated
    header=$(echo "${file_diff}" | head -50)
    footer=$(echo "${file_diff}" | tail -50)
    truncated=$((total_lines - 100))

    echo "${header}"
    echo ""
    echo "... [${truncated} lines truncated - no review comments, CI passed] ..."
    echo ""
    echo "${footer}"
  fi
}

# --- Preflight ---
if [[ ! -x "${CLAUDE_CLI}" ]]; then
  log_error "Claude CLI not found at: ${CLAUDE_CLI}"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  log_error "gh CLI not found"
  exit 1
fi

# --- Parse arguments ---
# Expected: pr merge [PR_NUMBER] [--flags...]
# PR number might be positional or we use current branch's PR

shift 2 # Remove "pr" and "merge"

PR_NUMBER=""
for arg in "$@"; do
  # If arg is a number, it's the PR number
  if [[ "${arg}" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="${arg}"
    break
  fi
done

# --- Fetch PR data ---
log_info "Fetching PR review data..."

PR_JSON_FIELDS="number,title,state,reviews,comments,reviewDecision,statusCheckRollup"
PR_JSON_FIELDS_FALLBACK="number,title,state,reviews,comments,reviewDecision"

# Fetch with statusCheckRollup first; fall back without it if the PAT lacks
# Checks permission (fine-grained PATs cannot access the Checks API).
_fetch_pr_json() {
  local -a pr_args=()
  [[ -n "${1:-}" ]] && pr_args+=("$1")
  local result
  for fields in "${PR_JSON_FIELDS}" "${PR_JSON_FIELDS_FALLBACK}"; do
    result=$(command gh pr view "${pr_args[@]}" --json "${fields}" 2>&1) && {
      echo "${result}"
      return 0
    }
    if [[ "${fields}" == "${PR_JSON_FIELDS}" ]] && [[ "${result}" == *"not accessible by personal access token"* ]]; then
      log_warn "statusCheckRollup not accessible — retrying without it"
      continue
    fi
    break
  done
  log_error "Failed to fetch PR ${1:-for current branch}"
  log_error "${result}"
  return 1
}

if [[ -n "${PR_NUMBER}" ]]; then
  PR_JSON=$(_fetch_pr_json "${PR_NUMBER}") || exit 1
else
  PR_JSON=$(_fetch_pr_json) || exit 1
  PR_NUMBER=$(echo "${PR_JSON}" | jq -r '.number')
fi

PR_TITLE=$(echo "${PR_JSON}" | jq -r '.title')
REVIEW_DECISION=$(echo "${PR_JSON}" | jq -r '.reviewDecision // "NONE"')

# Extract and format CI check status
STATUS_CHECKS=$(echo "${PR_JSON}" | jq -r '.statusCheckRollup // [] | if length == 0 then "No CI checks configured" else .[] | "- \(.name): \(.status) (\(.conclusion // "pending"))" end' 2>&1) || {
  log_warn "Could not parse status checks"
  STATUS_CHECKS="Status checks unavailable"
}

log_info "PR #${PR_NUMBER}: ${PR_TITLE}"
log_info "Review decision: ${REVIEW_DECISION}"

# --- Check for NEUTRAL CI status (blocking) ---
# Sentry/Seer sets status to "neutral" when there are unresolved comments
# This is a hard block - don't proceed to AI analysis
# Exclude Netlify informational checks that return NEUTRAL when nothing changed:
# - "Pages changed" / "Pages changed - <site-name>" - no pages modified
# - "Header rules" / "Header rules - <site-name>" - no headers modified
# These checks are informational only; NEUTRAL means "nothing to validate"
NEUTRAL_CHECKS=$(echo "${PR_JSON}" | jq -r '
  .statusCheckRollup // []
  | .[]
  | select(
      .conclusion == "NEUTRAL"
      and (.name | startswith("Pages changed") | not)
      and (.name | startswith("Header rules") | not)
    )
  | "- \(.name): \(.conclusion)"
' 2>&1) || true

if [[ -n "${NEUTRAL_CHECKS}" ]]; then
  echo "" >&2
  log_error "CI checks with NEUTRAL status (indicates unresolved issues):"
  echo "${NEUTRAL_CHECKS}" >&2
  echo "" >&2
  log_error "NEUTRAL status means the check found issues that need attention."
  log_error "Common causes:"
  log_error "  - Sentry/Seer Code Review: Has inline comments on code"
  log_error "  - Other reviewers: Requested changes not yet addressed"
  echo "" >&2
  log_error "Actions:"
  log_error "  1. View PR comments: gh pr view ${PR_NUMBER} --comments"
  log_error "  2. Check inline code comments on GitHub"
  log_error "  3. Address all review findings"
  log_error "  4. Push fixes and wait for checks to pass"
  echo "" >&2
  echo "   💡 TIP: If you've already resolved these issues and the comments are outdated," >&2
  echo "      add a new PR comment explaining what was fixed, then attempt the merge again." >&2
  echo "      The reviewer will see your update and re-analyze the current state." >&2
  echo "" >&2
  log_error "Merge blocked - resolve NEUTRAL checks first"
  exit 1
fi

# --- Fetch detailed review comments ---
# Get review threads which include inline comments
REVIEW_COMMENTS=$(command gh pr view "${PR_NUMBER}" --comments 2>&1) || {
  log_warn "Could not fetch detailed comments, continuing with basic review data"
  REVIEW_COMMENTS=""
}

# --- Fetch inline review comments (where Sentry bot posts) ---
# These are comments on specific lines of code, separate from review summaries
REPO_OWNER=$(command gh repo view --json owner -q '.owner.login' 2>&1) || {
  log_warn "Could not determine repo owner"
  REPO_OWNER=""
}
REPO_NAME=$(command gh repo view --json name -q '.name' 2>&1) || {
  log_warn "Could not determine repo name"
  REPO_NAME=""
}

INLINE_COMMENTS=""
if [[ -n "${REPO_OWNER}" && -n "${REPO_NAME}" ]]; then
  log_info "Fetching inline review comments (including bot comments)..."
  INLINE_COMMENTS=$(command gh api "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/comments" 2>&1) || {
    log_warn "Could not fetch inline review comments"
    INLINE_COMMENTS=""
  }

  # Filter out outdated comments (code has changed since comment was made)
  if [[ -n "${INLINE_COMMENTS}" && "${INLINE_COMMENTS}" != "[]" ]]; then
    INLINE_COMMENTS_FILTERED=$(echo "${INLINE_COMMENTS}" | jq '[.[] | select(.outdated != true)]' 2>&1) || {
      log_warn "Could not filter outdated comments, using all comments"
      INLINE_COMMENTS_FILTERED="${INLINE_COMMENTS}"
    }
  else
    INLINE_COMMENTS_FILTERED="[]"
  fi

  # Fetch review thread resolution status via GraphQL
  log_info "Checking review thread resolution status..."
  GRAPHQL_QUERY=$(
    cat <<'GRAPHQL_EOF'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(last: 100) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              databaseId
            }
          }
        }
      }
    }
  }
}
GRAPHQL_EOF
  )

  REVIEW_THREADS=$(command gh api graphql -f query="${GRAPHQL_QUERY}" -f owner="${REPO_OWNER}" -f name="${REPO_NAME}" -F number="${PR_NUMBER}" 2>&1) || {
    log_warn "Could not fetch review thread resolution status"
    REVIEW_THREADS=""
  }

  # Build a list of resolved thread comment IDs
  RESOLVED_COMMENT_IDS=""
  if [[ -n "${REVIEW_THREADS}" ]]; then
    RESOLVED_COMMENT_IDS=$(echo "${REVIEW_THREADS}" | jq -r '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true) | .comments.nodes[].databaseId' 2>&1) || {
      log_warn "Could not extract resolved comment IDs"
      RESOLVED_COMMENT_IDS=""
    }
  fi

  # Filter out comments from resolved threads
  if [[ "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
    # Build array of resolved comment IDs
    if [[ -z "${RESOLVED_COMMENT_IDS}" ]]; then
      RESOLVED_IDS_ARRAY="[]"
    else
      RESOLVED_IDS_ARRAY=$(echo "${RESOLVED_COMMENT_IDS}" | jq -R -s 'split("\n") | map(select(length > 0) | tonumber)')
    fi

    RESOLVED_COUNT=$(echo "${RESOLVED_IDS_ARRAY}" | jq 'length')
    if [[ "${RESOLVED_COUNT}" -gt 0 ]]; then
      log_info "Filtering ${RESOLVED_COUNT} resolved comment(s)"
      # Use index to check if comment ID exists in resolved IDs array
      INLINE_COMMENTS_FILTERED=$(echo "${INLINE_COMMENTS_FILTERED}" | jq --argjson resolved_ids "${RESOLVED_IDS_ARRAY}" '[.[] | select(.id as $id | $resolved_ids | index($id) | not)]' 2>&1) || {
        log_warn "Could not filter resolved comments"
      }
    fi
  fi

  # Format filtered comments for readability
  if [[ -n "${INLINE_COMMENTS_FILTERED}" && "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
    COMMENT_COUNT=$(echo "${INLINE_COMMENTS_FILTERED}" | jq 'length')
    log_info "Found ${COMMENT_COUNT} active inline comment(s) (filtered out outdated/resolved)"

    INLINE_COMMENTS_FORMATTED=$(echo "${INLINE_COMMENTS_FILTERED}" | jq -r '.[] | "---\nAuthor: \(.user.login)\nFile: \(.path):\(.line // .original_line // "unknown")\nComment: \(.body)\n"' 2>&1) || {
      log_warn "Could not format inline comments, using raw JSON"
      INLINE_COMMENTS_FORMATTED="${INLINE_COMMENTS_FILTERED}"
    }
  else
    INLINE_COMMENTS_FORMATTED="No active inline comments (all outdated or resolved)"
  fi
else
  log_warn "Skipping inline comments fetch (repo info unavailable)"
  INLINE_COMMENTS_FORMATTED="Inline comments unavailable"
fi

# Get the full diff for context
PR_DIFF=$(command gh pr diff "${PR_NUMBER}" 2>&1) || {
  log_warn "Could not fetch PR diff"
  PR_DIFF=""
}

# --- Build targeted diff context ---
# Extract files mentioned in inline comments - these are critical and must be included
COMMENTED_FILES=""
if [[ -n "${INLINE_COMMENTS_FILTERED}" && "${INLINE_COMMENTS_FILTERED}" != "[]" ]]; then
  # Filter out empty lines to prevent empty alternations in regex pattern
  COMMENTED_FILES=$(echo "${INLINE_COMMENTS_FILTERED}" | jq -r '.[].path' | grep -v '^[[:space:]]*$' | sort -u || true)
fi

DIFF_LINES=$(echo "${PR_DIFF}" | wc -l)

if [[ ${DIFF_LINES} -le 1000 ]]; then
  # Small diff - include everything
  log_info "Diff is ${DIFF_LINES} lines (under threshold), including full diff"
  TARGETED_DIFF="${PR_DIFF}"
else
  # Large diff - build smart targeted context
  log_info "Diff is large (${DIFF_LINES} lines), building smart targeted context..."

  # Check if CI passed
  CI_PASSED=false
  if echo "${STATUS_CHECKS}" | grep -qE "(SUCCESS|PASS)"; then
    CI_PASSED=true
    log_info "CI passed - enabling smart data file filtering"
  fi

  # Initialize counters (required before arithmetic operations with set -e)
  FULL_DIFF_COUNT=0
  SUMMARIZED_COUNT=0
  TRUNCATED_COUNT=0

  # Process each file based on classification
  PROCESSED_DIFF=""
  FILE_SUMMARIES=""

  while IFS= read -r file_path; do
    if [[ -z "${file_path}" ]]; then
      continue
    fi

    file_diff=$(extract_file_diff "${PR_DIFF}" "${file_path}")

    # Decision tree: Security-first design
    # Security-critical files are checked BEFORE data files to ensure
    # sensitive JSON/config files (credentials, secrets) are never summarized
    if is_security_critical "${file_path}"; then
      # Always show security-critical files in full
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))

    elif has_inline_comments "${file_path}"; then
      # Always show files with inline comments in full
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))

    elif is_data_file "${file_path}"; then
      if [[ "${CI_PASSED}" == true ]]; then
        # Data file + CI passed + no comments = summarize
        summary=$(summarize_data_file "${file_path}" "${file_diff}")
        FILE_SUMMARIES+="${summary}
"
        SUMMARIZED_COUNT=$((SUMMARIZED_COUNT + 1))
      else
        # CI failed - include data file for debugging
        PROCESSED_DIFF+="${file_diff}
"
        FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))
      fi

    elif [[ "${CI_PASSED}" == true ]]; then
      # Regular code file + CI passed + no comments = truncate
      truncated=$(truncate_code_diff "${file_diff}")
      PROCESSED_DIFF+="${truncated}
"
      TRUNCATED_COUNT=$((TRUNCATED_COUNT + 1))

    else
      # CI failed - show everything
      PROCESSED_DIFF+="${file_diff}
"
      FULL_DIFF_COUNT=$((FULL_DIFF_COUNT + 1))
    fi
  done < <(get_changed_files "${PR_DIFF}" || true)

  # Build final targeted diff
  TARGETED_DIFF="=== Smart Diff Context (${DIFF_LINES} total lines) ===

Files shown in full: ${FULL_DIFF_COUNT}
Files truncated (no comments, CI passed): ${TRUNCATED_COUNT}
Data files summarized (CI validated): ${SUMMARIZED_COUNT}

=== Full/Truncated Diffs ===

${PROCESSED_DIFF}

=== Data Files (CI Validated) ===

${FILE_SUMMARIES}"

  TARGETED_LINES=$(echo "${TARGETED_DIFF}" | wc -l)
  log_info "Smart diff built: ${TARGETED_LINES} lines (down from ${DIFF_LINES})"
fi

# Use targeted diff for analysis
PR_DIFF="${TARGETED_DIFF}"

# --- Build the analysis prompt ---
read -r -d '' ANALYSIS_PROMPT <<'PROMPT_EOF' || true
You are analyzing a GitHub PR to determine if it's safe to merge.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

IMPORTANT - PR DIFF FORMAT:
The PR diff provided uses smart filtering to reduce token usage while preserving critical context:
- **Full diffs**: Files with inline comments or security-critical files (auth, payment, db, etc.)
- **Truncated diffs**: Code files without comments (first/last 50 lines shown, CI passed)
- **Summarized**: Data files validated by CI (JSON, lock files, etc.)

If a file shows "CI validated data file (not shown)", trust CI validation unless:
1. The file type is security-critical (credentials, secrets)
2. Inline comments specifically flag issues with that file
3. CI checks show failures

Focus your review on:
1. Files with inline comments (highest priority - shown in full)
2. Security-critical code files (always shown in full)
3. Code logic in truncated files (meaningful sections shown)

Identify:
1. **Unresolved concerns** - Issues raised but not addressed in subsequent commits
2. **Requested changes** - Explicit change requests not yet implemented
3. **Blocking issues** - Security concerns, bugs flagged by reviewers
4. **CI failures** - Failed checks or tests
5. **Inline file comments** - CRITICAL: Check comments posted directly on code lines (especially from bots)

CRITICAL RULES:
- **CI CHECK STATUS**: Check status is provided in "CI Check Status" section
  - FAILURE/NEUTRAL conclusion = blocking issue that must be addressed
  - SUCCESS = CI passed, but still check inline comments for specific concerns
  - PENDING = check still running, cannot merge yet
- **INLINE COMMENTS**: Bots like "sentry[bot]" and "Seer" post comments on specific code lines, NOT as review summaries
  - These appear in the "Inline Review Comments" section below
  - IMPORTANT: Outdated comments (code changed) and resolved threads are already filtered out
  - Only active, unresolved inline comments are shown
  - If no active inline comments exist, the issue was likely addressed
- If all remote CI checks pass, defer to CI unless reviewer explicitly flags security risk
- Review comments may reference code that was later fixed - check timestamps
- Distinguish "reviewer suggested" (non-blocking) from "reviewer blocked" (blocking)
- Automated reviewers (Seer, Claude bot, sentry[bot]) are informational - prioritize human reviewers and CI

Reviewer context:
- "Seer", "Claude", and "sentry[bot]" are automated bots
- sentry[bot] posts inline comments on specific code lines (not review summaries)
- Human reviewers override bots
- Passing CI indicates issues were addressed
- Inline comments below have been filtered: outdated comments (code changed) and resolved threads are excluded

Respond in this format:

VERDICT: [SAFE_TO_MERGE or BLOCK_MERGE]

[If BLOCK_MERGE, list each issue:]
ISSUE: [one-line description]
SOURCE: [reviewer or "CI" or "sentry[bot]"]
LOCATION: [file:line if inline comment]
STATUS: [UNRESOLVED or UNCLEAR]
DETAILS: [what needs to happen]

[If SAFE_TO_MERGE:]
All review comments (including inline comments) appear resolved or are non-blocking. [Brief summary]

Be conservative but pragmatic. If CI passes and concerns look addressed, allow merge.
PROMPT_EOF

# --- Build full prompt ---
FULL_PROMPT="${ANALYSIS_PROMPT}

PR #${PR_NUMBER}: ${PR_TITLE}
Review Decision: ${REVIEW_DECISION}

=== CI Check Status ===
${STATUS_CHECKS}

=== Review Data (JSON) ===
${PR_JSON}

=== Review Comments ===
${REVIEW_COMMENTS}

=== Active Inline Review Comments (outdated/resolved filtered out) ===
${INLINE_COMMENTS_FORMATTED}

=== PR Diff (for context) ===
\`\`\`diff
${PR_DIFF}
\`\`\`"

# --- Call Claude CLI ---
PROMPT_SIZE=${#FULL_PROMPT}
PROMPT_LINES=$(echo "${FULL_PROMPT}" | wc -l)
log_info "Prompt size: ${PROMPT_SIZE} bytes, ${PROMPT_LINES} lines"
log_info "Analyzing review comments..."

ANALYSIS_TEXT=$(echo "${FULL_PROMPT}" | timeout "${TIMEOUT_SECONDS}" "${CLAUDE_CLI}" -p --tools "" --no-session-persistence 2>&1) || {
  EXIT_CODE=$?
  if [[ ${EXIT_CODE} -eq 124 ]]; then
    log_error "Analysis timed out after ${TIMEOUT_SECONDS}s"
  else
    log_error "Claude CLI failed (exit code: ${EXIT_CODE})"
    log_error "${ANALYSIS_TEXT}"
  fi
  exit 1
}

if [[ -z "${ANALYSIS_TEXT}" ]]; then
  log_error "Empty response from Claude CLI"
  exit 1
fi

# --- Evaluate verdict ---
echo "" >&2
echo "${ANALYSIS_TEXT}" >&2
echo "" >&2

# Parse verdict - extract the line containing VERDICT and check its value
# This handles cases where environment check or other output appears before verdict
VERDICT_LINE=$(echo "${ANALYSIS_TEXT}" | grep -E "^VERDICT:" | head -1)

if [[ -z "${VERDICT_LINE}" ]]; then
  # Couldn't find verdict - fail safe (block merge)
  log_warn "Could not parse analysis verdict - no 'VERDICT:' line found"
  log_warn "Blocking merge out of caution - review output above"
  exit 1
fi

if echo "${VERDICT_LINE}" | grep -qE "SAFE_TO_MERGE"; then
  # --- Merge Authorization Lock ---
  MERGE_LOCK="${HOME}/.claude/hooks/merge-lock.sh"
  if [[ -x "${MERGE_LOCK}" ]]; then
    if ! "${MERGE_LOCK}" check "${PR_NUMBER}" 2>/dev/null; then
      echo "" >&2
      log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      log_error "MERGE AUTHORIZATION REQUIRED"
      log_error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "" >&2
      log_error "Review passed, but merge requires human authorization."
      log_error ""
      log_error "To authorize (valid 30 min):"
      log_error "  ~/.claude/hooks/merge-lock.sh authorize ${PR_NUMBER} \"reason\""
      log_error ""
      log_error "Then retry: gh pr merge ${PR_NUMBER}"
      echo "" >&2
      exit 1
    fi
    log_success "Merge authorization verified"
  fi
  log_success "PR review analysis passed - safe to merge"
  exit 0
elif echo "${VERDICT_LINE}" | grep -qE "BLOCK_MERGE"; then
  log_error "PR has unresolved review issues - merge blocked"
  echo "" >&2
  echo "   Address the issues above before merging." >&2
  echo "" >&2
  echo "   💡 TIP: If you've already resolved these issues and the comments are outdated," >&2
  echo "      add a new PR comment explaining what was fixed, then attempt the merge again." >&2
  echo "      The reviewer will see your update and re-analyze the current state." >&2
  echo "" >&2
  echo "   To bypass (emergency only):" >&2
  echo "   OBTAIN EXPLICIT PERMISSION and then command gh pr merge ${PR_NUMBER}" >&2
  echo "" >&2
  exit 1
else
  # Verdict line exists but contains neither expected value
  log_warn "Could not parse analysis verdict - unexpected format: ${VERDICT_LINE}"
  log_warn "Blocking merge out of caution - review output above"
  exit 1
fi
