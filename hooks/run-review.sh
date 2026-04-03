#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# run-review.sh — Automated code review via Claude CLI
# =========================================================
#
# Called by commit-msg hook to perform actual code review
# before allowing commits. Uses installed Claude CLI with
# Max subscription (no API charges).
#
# USAGE:
#   git diff --cached | ~/.claude/hooks/run-review.sh
#   git diff main...HEAD | ~/.claude/hooks/run-review.sh --mode=full-diff
#
# EXIT CODES:
#   0 = Review passed (no blocking issues)
#   1 = Review failed (issues found or error)
#
# CONFIGURATION (via git config):
#   review.maxLines        - Max lines for full review (default: 1000)
#   review.skipThreshold   - Skip AI review beyond this (default: 2500)
#   review.chunkSize       - Max lines per file in chunked mode (default: 800)
#
# EXAMPLES:
#   git config --global review.maxLines 2000
#   git config review.skipThreshold 5000
#
# PROGRESSIVE REVIEW STRATEGY:
#   - Small diffs (≤ maxLines): Full review
#   - Medium diffs (maxLines to skipThreshold): Chunked file-by-file review
#   - Large diffs (> skipThreshold): BLOCKED - must split into smaller commits
#
# STRICT MODE: This script blocks commits when:
#   - Review finds code quality issues (BLOCKING severity)
#   - Review times out (incomplete review)
#   - Agent errors occur (incomplete review)
#   - Diff is too large for automated review
#   - Review output cannot be parsed (unverified result)
#
# Rationale: Unverified code is unsafe code. If the review cannot complete,
# we cannot verify the code is safe to commit.
#
# =========================================================

# --- Configuration ---
CLAUDE_CLI="${CLAUDE_CLI:-${HOME}/.local/bin/claude}"
TIMEOUT_SECONDS=$(git config --get --type=int review.timeout 2>/dev/null || echo "120")

# Progressive review configuration (with git config overrides)
REVIEW_MAX_LINES=$(git config --get --type=int review.maxLines 2>/dev/null || echo "1000")
REVIEW_SKIP_THRESHOLD=$(git config --get --type=int review.skipThreshold 2>/dev/null || echo "2500")
REVIEW_CHUNK_SIZE=$(git config --get --type=int review.chunkSize 2>/dev/null || echo "800")

# --- Mode ---
REVIEW_MODE="commit"  # default: pre-commit review (code-reviewer + adversarial)
for arg in "$@"; do
  case "${arg}" in
    --mode=full-diff) REVIEW_MODE="full-diff" ;;
    --mode=codebase) REVIEW_MODE="codebase" ;;
    --mode=*) echo "Unknown mode: ${arg}" >&2; exit 1 ;;
  esac
done

# Override timeout for codebase mode (longer due to tool-access exploration)
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  TIMEOUT_SECONDS=$(git config --get --type=int review.codebaseTimeout 2>/dev/null || echo "300")
fi

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Helpers ---
log_info() { echo -e "${BLUE}[review]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[review]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[review]${NC} $*" >&2; }
log_error() { echo -e "${RED}[review]${NC} $*" >&2; }

# --- Shared issue library (for --mode=codebase non-blocking issues) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-issues.sh
source "${_LIB_DIR}/lib-review-issues.sh"

# Resolve repo metadata for issue creation (best-effort)
if [[ -z "${REPO_OWNER:-}" ]]; then
  _remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ "${_remote_url}" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    export REPO_OWNER="${BASH_REMATCH[1]}"
    export REPO_NAME="${BASH_REMATCH[2]}"
  fi
fi

# --- Preflight ---
if [[ ! -x "${CLAUDE_CLI}" ]]; then
  log_error "Claude CLI not found at: ${CLAUDE_CLI}"
  log_error "Set CLAUDE_CLI env var to override location"
  exit 1
fi

# --- Agent invocation function ---
invoke_agent() {
  local agent_name="$1"
  local prompt="$2"
  local cache_file="$3"

  # Check cache first
  if [[ -f "${cache_file}" ]]; then
    local cached_verdict
    cached_verdict=$(head -1 "${cache_file}")
    if [[ "${cached_verdict}" == "PASS" ]]; then
      log_info "${agent_name}: cached PASS"
      echo "VERDICT: PASS (cached)"
      return 0
    fi
    # Cache was FAIL or invalid - re-review
    rm -f "${cache_file}"
  fi

  log_info "Running ${agent_name} agent..."

  local start_time
  start_time=$(date +%s)

  # Invoke agent via Claude CLI
  # Unset CLAUDECODE to allow invocation from within a Claude Code session.
  # Claude CLI 2.1.50+ refuses to start if CLAUDECODE is set (anti-nesting check).
  # Safe here because --no-session-persistence + piped input = non-interactive child process.
  local agent_output
  local exit_code=0
  # Use || to prevent set -e from propagating if the CLI exits non-zero.
  # exit_code is then set to the actual failure code for the handler below.
  agent_output=$(echo "${prompt}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "${agent_name}" -p --tools "" --no-session-persistence 2>&1) || exit_code=$?

  # Handle timeout - BLOCK commit (strict mode)
  if [[ ${exit_code} -eq 124 ]]; then
    log_error "${agent_name} timed out after ${TIMEOUT_SECONDS}s"
    log_error "BLOCKING: Review timeout means review did not complete."
    log_error ""
    log_error "Options:"
    log_error "  1. Retry the commit (review will run again)"
    log_error "  2. Increase timeout: git config review.timeout 300"
    log_error "  3. Split into smaller commits"
    echo "VERDICT: FAIL (timeout)"
    return 1
  elif [[ ${exit_code} -ne 0 ]]; then
    log_error "${agent_name} exited with error code ${exit_code}"
    log_error "BLOCKING: Agent error means review did not complete."
    log_error ""
    log_error "Options:"
    log_error "  1. Retry the commit (review will run again)"
    log_error "  2. Check Claude CLI: claude --version"
    echo "VERDICT: FAIL (agent error: ${exit_code})"
    return 1
  fi

  local end_time
  end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  log_info "${agent_name} completed in ${elapsed}s"

  # Return the output for parsing
  echo "${agent_output}"

  # Cache verdict if PASS
  if echo "${agent_output}" | grep -q "VERDICT: PASS"; then
    echo "PASS" >"${cache_file}"
    date -u +%Y-%m-%dT%H:%M:%SZ >>"${cache_file}"
  fi
}

# --- Helper Functions for Progressive Review ---

show_large_diff_summary() {
  local total_lines="$1"

  echo "" >&2
  echo "=== LARGE DIFF SUMMARY ===" >&2
  echo "" >&2

  # File statistics
  local files_changed
  files_changed=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')

  echo "Total changes: ${total_lines} lines across ${files_changed} files" >&2
  echo "" >&2

  # Top changed files
  echo "Top 10 changed files:" >&2
  git diff --cached --numstat 2>/dev/null \
    | sort -rn \
    | head -10 \
    | awk '{printf "  %5d + | %5d - | %s\n", $1, $2, $3}' >&2 || true

  echo "" >&2
  log_info "AI review skipped for very large diffs (${total_lines} > ${REVIEW_SKIP_THRESHOLD} lines)"
  log_info "To review manually: git diff --cached | claude --agent code-reviewer -p --tools \"\""
  log_warn "Allowing commit without AI review (diff too large is not a code quality issue)"
  echo "" >&2
}

perform_chunked_review() {
  local total_lines="$1"

  log_info "Performing chunked review (${total_lines} lines total, reviewing files ≤ ${REVIEW_CHUNK_SIZE} lines each)"

  # Get list of changed files
  local files
  files=$(git diff --cached --name-only 2>/dev/null || echo "")

  if [[ -z "${files}" ]]; then
    log_warn "No files to review"
    return 0
  fi

  local file_count
  file_count=$(echo "${files}" | wc -l | tr -d ' ')

  log_info "Reviewing ${file_count} files individually..."

  local overall_verdict="PASS"
  local blocking_count=0
  local warning_count=0
  local reviewed_files=0
  local skipped_files=0
  local issues_output=""

  # Review each file separately
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    local file_diff
    file_diff=$(git diff --cached -U10 -- "${file}" 2>/dev/null || echo "")

    [[ -z "${file_diff}" ]] && continue

    local file_lines
    file_lines=$(echo "${file_diff}" | wc -l | tr -d ' ')

    # Skip if file diff is too large
    if [[ ${file_lines} -gt ${REVIEW_CHUNK_SIZE} ]]; then
      log_warn "Skipping ${file} (${file_lines} lines > ${REVIEW_CHUNK_SIZE} chunk size)"
      ((skipped_files += 1))
      continue
    fi

    # Build prompt for this file
    local file_prompt
    file_prompt="Reviewing file: ${file}

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]
ISSUE: [one-line description]
SEVERITY: [BLOCKING or WARNING]
LOCATION: [file:line]
DETAILS: [explanation and fix]

Review this diff:

\`\`\`diff
${file_diff}
\`\`\`"

    # Create per-file cache key
    local file_cache_key
    file_cache_key=$(echo "${file_diff}" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "nocache")
    local file_cache="${CACHE_DIR}/${file//\//_}_${file_cache_key}"

    # Invoke agent for this file (|| prevents set -e from propagating on CLI failure)
    local file_output
    local agent_exit=0
    file_output=$(invoke_agent "code-reviewer" "${file_prompt}" "${file_cache}") || agent_exit=$?

    # If agent failed (timeout, error), skip this file — don't block the commit
    if [[ ${agent_exit} -ne 0 ]]; then
      log_warn "Agent timeout/error for ${file} - skipping this file"
      ((skipped_files += 1))
      continue
    fi

    # Parse verdict
    if echo "${file_output}" | grep -q "VERDICT: FAIL"; then
      if echo "${file_output}" | grep -q "SEVERITY: BLOCKING"; then
        ((blocking_count += 1))
        overall_verdict="FAIL"
      else
        ((warning_count += 1))
      fi

      # Accumulate issues for final display
      issues_output="${issues_output}

=== Issues in ${file} ===
${file_output}"
    fi

    ((reviewed_files += 1))
  done <<<"${files}"

  # Display accumulated issues
  if [[ -n "${issues_output}" ]]; then
    echo "${issues_output}" >&2
    echo "" >&2
  fi

  # Summary
  echo "" >&2
  echo "=== CHUNKED REVIEW SUMMARY ===" >&2
  echo "Reviewed: ${reviewed_files}/${file_count} files" >&2
  [[ ${skipped_files} -gt 0 ]] && echo "Skipped (too large or errors): ${skipped_files} files" >&2
  echo "Blocking issues: ${blocking_count}" >&2
  echo "Warnings: ${warning_count}" >&2
  echo "" >&2

  # Write results to REVIEW_LOG (global; || true guards set -e)
  {
    printf '=== CHUNKED REVIEW ===\n'
    printf 'Reviewed: %d/%d files | Blocking: %d | Warnings: %d\n' \
      "${reviewed_files}" "${file_count}" "${blocking_count}" "${warning_count}"
    if [[ ${skipped_files} -gt 0 ]]; then
      printf 'Files skipped (agent error or oversized chunk): %d\n' "${skipped_files}"
    fi
    if [[ -n "${issues_output}" ]]; then
      printf '%s\n' "${issues_output}"
    fi
  } >>"${REVIEW_LOG}" || true

  if [[ "${overall_verdict}" == "FAIL" ]]; then
    log_error "Chunked review found ${blocking_count} blocking issues in reviewed files"
    echo "" >&2
    echo "💡 Tip: If this appears to be a false positive, force single-pass review:" >&2
    echo "   git config review.maxLines 2500  # review whole diff at once" >&2
    echo "   git commit                        # retry" >&2
    echo "   git config --unset review.maxLines" >&2
    return 1
  else
    log_success "Chunked review passed (${reviewed_files} files reviewed)"
    return 0
  fi
}

# --- Read diff from stdin ---
DIFF=$(cat)

# --- Review log: scoped to this repo's .git/ directory ---
# Rationale: A single global log is overwritten by concurrent sessions in other
# repos, making cross-repo contamination undetectable (incident 2026-03-08).
# Per-repo log + identity fields let the controller confirm the log matches
# the repo and commit they just made.
GIT_DIR_PATH="$(git rev-parse --git-dir 2>/dev/null || echo ".git")"
REVIEW_LOG="${REVIEW_LOG:-${GIT_DIR_PATH}/last-review-result.log}"
_review_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ || true)
_review_repo=$(cdup=$(git rev-parse --show-cdup 2>/dev/null) && cd "./${cdup:-.}" >/dev/null 2>&1 && pwd -L || echo "unknown")
_review_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
_review_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
} >"${REVIEW_LOG}" || true

# Global pointer: keep ~/.claude/last-review-result.log pointed at the most
# recent per-repo log. Controllers checking the global path will see identity
# fields that reveal cross-repo contamination immediately.
_global_log="${HOME}/.claude/last-review-result.log"
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
  printf 'log: %s\n' "${REVIEW_LOG}"
} >"${_global_log}" || true

_ec=0 # captured by EXIT trap; declared here so shellcheck sees the assignment
trap '_ec=$?; [[ -n "${REVIEW_LOG:-}" ]] && printf "exit_code: %d\n" "$_ec" >> "${REVIEW_LOG}" || true' EXIT

if [[ -z "${DIFF}" ]]; then
  log_warn "No staged changes to review"
  printf 'skipped: no staged changes\n' >>"${REVIEW_LOG}" || true
  exit 0
fi

# --- Review caching (skip review if diff unchanged since last PASS) ---
CACHE_DIR="${GIT_DIR_PATH}/claude-review-cache"
mkdir -p "${CACHE_DIR}"

# Clean up cache entries older than 30 days to prevent unbounded growth
find "${CACHE_DIR}" -type f -mtime +30 -delete 2>/dev/null || true

DIFF_HASH=$(echo "${DIFF}" | shasum -a 256 | awk '{print $1}')
CACHE_FILE="${CACHE_DIR}/${DIFF_HASH}"

if [[ -f "${CACHE_FILE}" ]]; then
  CACHED_VERDICT=$(head -1 "${CACHE_FILE}")
  if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
    log_success "Review cached: identical diff previously passed"
    printf 'skipped: cached PASS\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
  # If cached verdict was FAIL or unparseable, re-review (code may have changed)
  rm -f "${CACHE_FILE}"
fi

# Progressive review strategy based on diff size
DIFF_LINES=$(echo "${DIFF}" | wc -l | tr -d ' ')

if [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt ${REVIEW_SKIP_THRESHOLD} ]]; then
  show_large_diff_summary "${DIFF_LINES}"
  log_error ""
  log_error "BLOCKING: Diff too large for automated review (${DIFF_LINES} lines)"
  log_error ""
  log_error "Options:"
  log_error "  1. Split into smaller commits (recommended)"
  log_error "  2. Increase threshold: git config review.skipThreshold 5000"
  printf 'blocked: diff too large (%d lines > %d threshold)\n' "${DIFF_LINES}" "${REVIEW_SKIP_THRESHOLD}" >>"${REVIEW_LOG}" || true
  exit 1

elif [[ ${DIFF_LINES} -gt ${REVIEW_MAX_LINES} ]]; then
  # Medium diff - use chunked review
  log_warn "Diff is large (${DIFF_LINES} lines), using chunked file-by-file review"
  printf 'diff_lines: %d (chunked review)\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true
  perform_chunked_review "${DIFF_LINES}"
  exit $? # Exit with chunked review result

elif [[ ${DIFF_LINES} -gt $((REVIEW_MAX_LINES * 3 / 4)) ]]; then
  # Approaching limit - warn but proceed with full review
  log_warn "Diff is approaching review limit (${DIFF_LINES}/${REVIEW_MAX_LINES} lines)"
fi

# Small enough for full review - continue with existing logic below

# --- Check for empty diff (permission/mode changes only) ---
# Skip review if diff contains no actual code changes
if ! echo "${DIFF}" | grep -qE '^[+-][^+-]'; then
  log_info "No code changes detected (permission/metadata only) - skipping review"
  printf 'skipped: permission/metadata only\n' >>"${REVIEW_LOG}" || true
  exit 0
fi

# --- Check for documentation-only changes ---
# Skip code review for markdown files - they're handled by markdownlint
CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
if [[ -n "${CHANGED_FILES}" ]]; then
  # Check if ALL changed files are markdown
  NON_MD_FILES=$(echo "${CHANGED_FILES}" | grep -vE '\.md$' || echo "")
  if [[ -z "${NON_MD_FILES}" ]]; then
    log_info "Markdown-only changes detected - skipping code review (handled by markdownlint)"
    printf 'skipped: markdown-only\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
fi

# --- Check for lockfile-only changes ---
# Skip code review for lockfiles - they're generated files
if [[ -n "${CHANGED_FILES}" ]]; then
  # Check if ALL changed files are lockfiles
  NON_LOCK_FILES=$(echo "${CHANGED_FILES}" | grep -vE '(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|composer\.lock)$' || echo "")
  if [[ -z "${NON_LOCK_FILES}" ]]; then
    log_info "Lockfile-only changes detected - skipping code review (generated files)"
    printf 'skipped: lockfile-only\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
fi

# --- Full-diff mode (pre-push cross-file review) ---
if [[ "${REVIEW_MODE}" == "full-diff" ]]; then
  log_info "Full-diff review: analyzing complete feature branch diff"
  log_info "Diff size: ${DIFF_LINES} lines"

  FULL_DIFF_CACHE="${CACHE_DIR}/full-diff-${DIFF_HASH}"

  # Check cache
  if [[ -f "${FULL_DIFF_CACHE}" ]]; then
    CACHED_VERDICT=$(head -1 "${FULL_DIFF_CACHE}")
    if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
      log_success "Full-diff review cached: identical diff previously passed"
      printf 'full-diff: cached PASS\n' >>"${REVIEW_LOG}" || true
      exit 0
    fi
    rm -f "${FULL_DIFF_CACHE}"
  fi

  FULL_DIFF_PROMPT="You are performing a pre-push full-diff review of an entire feature branch.
This diff represents ALL changes from main to HEAD — the complete PR surface area.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on CROSS-FILE integration issues that per-commit reviews miss:
1. Cross-file consistency: Are interfaces used correctly across file boundaries?
2. State management: Do shared identifiers, IDs, or keys match across files?
3. Error propagation: Do errors flow correctly from source to handler across files?
4. Feature completeness: Are all entry points to new features discoverable?
5. Platform guards: If platform-specific code exists, are both paths tested?
6. Removed functionality: If UI elements or entry points were removed, is that intentional?
7. Security surface: Do auth/RLS/permission changes have corresponding test coverage?

Do NOT repeat per-line issues (those are caught in per-commit review).
Focus ONLY on issues visible when examining the full change set together.

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]

ISSUE: [one-line description]
SEVERITY: [BLOCKING or WARNING]
LOCATION: [file:line or file1+file2]
DETAILS: [explanation of the cross-file issue]

[If PASS:]

No cross-file integration issues found.

Review diff:
\`\`\`diff
${DIFF}
\`\`\`"

  FULL_DIFF_OUTPUT=$(invoke_agent "adversarial-reviewer" "${FULL_DIFF_PROMPT}" "${FULL_DIFF_CACHE}") || true

  [[ -n "${FULL_DIFF_OUTPUT}" ]] || FULL_DIFF_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

  echo "=== FULL-DIFF REVIEW (adversarial-reviewer) ===" >&2
  echo "${FULL_DIFF_OUTPUT}" >&2
  echo "" >&2

  { printf '=== FULL-DIFF REVIEW ===\n%s\n' "${FULL_DIFF_OUTPUT}"; } >>"${REVIEW_LOG}" || true

  if echo "${FULL_DIFF_OUTPUT}" | grep -q "VERDICT: PASS"; then
    printf 'full-diff: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Full-diff review passed"
    exit 0
  elif echo "${FULL_DIFF_OUTPUT}" | grep -q "VERDICT: FAIL"; then
    if echo "${FULL_DIFF_OUTPUT}" | grep -q "SEVERITY: BLOCKING"; then
      printf 'full-diff: FAIL (blocking)\n' >>"${REVIEW_LOG}" || true
      log_error "Full-diff review found blocking cross-file issues"
      exit 1
    else
      printf 'full-diff: FAIL (warnings only)\n' >>"${REVIEW_LOG}" || true
      log_warn "Full-diff review found warnings (non-blocking)"
      exit 0
    fi
  else
    log_error "Could not parse full-diff review verdict"
    log_error "Output was:"
    echo "${FULL_DIFF_OUTPUT}" | head -20 >&2
    printf 'full-diff: FAIL (unparseable)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi
fi

# --- Codebase mode (pre-push whole-codebase review with tool access) ---
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  log_info "Codebase review: analyzing diff with full codebase tool access"
  log_info "Diff size: ${DIFF_LINES} lines | Timeout: ${TIMEOUT_SECONDS}s"

  CODEBASE_CACHE="${CACHE_DIR}/codebase-${DIFF_HASH}"

  # Check cache
  if [[ -f "${CODEBASE_CACHE}" ]]; then
    CACHED_VERDICT=$(head -1 "${CODEBASE_CACHE}")
    if [[ "${CACHED_VERDICT}" == "PASS" ]]; then
      log_success "Codebase review cached: identical diff previously passed"
      printf 'codebase: cached PASS\n' >>"${REVIEW_LOG}" || true
      exit 0
    fi
    rm -f "${CODEBASE_CACHE}"
  fi

  # Write diff to temp file so the agent can re-read it via Read tool
  DIFF_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/codebase-review-diff.XXXXXX")
  printf '%s\n' "${DIFF}" >"${DIFF_TMPFILE}"

  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd -L)

  CODEBASE_PROMPT="You are performing a codebase-aware review of a feature branch diff.
You have full tool access: Read, Grep, Glob. Use them to explore the repository.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the analysis, then end with the verdict.

Repository root: ${REPO_ROOT}
Diff file (re-readable): ${DIFF_TMPFILE}

REVIEW PROCEDURE:
1. Read the diff file at ${DIFF_TMPFILE} to identify what changed.
2. For each changed file, use Read to view the FULL file for surrounding context.
3. Follow imports and references ONE level out — check callers/callees of changed functions.
4. Look specifically for:
   a. Field/contract violations: renamed or removed fields still referenced elsewhere
   b. Data flow bugs: values passed to wrong parameters, type mismatches
   c. Date/timezone inconsistencies: mixing UTC and local, wrong format strings
   d. Dead UI elements: buttons/links pointing to removed routes or handlers
   e. Cache key mismatches: cache writes and reads using different key patterns
   f. Platform-specific gotchas: iOS/Android/web divergence without guards

CLASSIFICATION:
- BLOCK: Issue is INTRODUCED by this diff (new bug, new inconsistency). These BLOCK the push.
- NON_BLOCKING_ISSUE: Issue is PRE-EXISTING (was there before this diff). These are filed as issues.

CRITICAL: Respond with this exact format:

If there are BLOCKING issues:

VERDICT: FAIL

ISSUE: <one-line title>
SEVERITY: BLOCKING
LOCATION: <file:line>
DETAILS: <explanation of the bug and how to fix it>

If there are NO blocking issues (with optional non-blocking issues):

VERDICT: PASS

No blocking issues found.

NON_BLOCKING_ISSUE:
TITLE: <one-line title>
SOURCE: pre-push whole-codebase review
LOCATION: <file:line>
DETAILS: <explanation of the pre-existing issue>
END_ISSUE"

  log_info "Running codebase reviewer with tool access..."
  codebase_start=$(date +%s)

  codebase_exit=0
  # Invoke WITHOUT --tools "" so agent gets default tool access (Read, Grep, Glob).
  # --allowedTools restricts to safe read-only tools only.
  CODEBASE_OUTPUT=$(echo "${CODEBASE_PROMPT}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "adversarial-reviewer" -p --allowedTools "Read,Grep,Glob" --no-session-persistence 2>&1) || codebase_exit=$?

  codebase_end=$(date +%s)
  codebase_elapsed=$(( codebase_end - codebase_start ))
  log_info "Codebase review completed in ${codebase_elapsed}s"

  # Clean up temp file
  rm -f "${DIFF_TMPFILE}"

  # Handle timeout
  if [[ ${codebase_exit} -eq 124 ]]; then
    log_error "Codebase review timed out after ${TIMEOUT_SECONDS}s"
    log_error "BLOCKING: Review timeout means review did not complete."
    log_error "Increase timeout: git config review.codebaseTimeout 600"
    printf 'codebase: FAIL (timeout)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi

  # Handle other CLI errors
  if [[ ${codebase_exit} -ne 0 ]]; then
    log_error "Codebase reviewer exited with error code ${codebase_exit}"
  fi

  [[ -n "${CODEBASE_OUTPUT}" ]] || CODEBASE_OUTPUT="VERDICT: FAIL (agent error: invoke produced no output)"

  echo "=== CODEBASE REVIEW ===" >&2
  echo "${CODEBASE_OUTPUT}" >&2

  # Parse verdict and handle results
  if echo "${CODEBASE_OUTPUT}" | grep -q "VERDICT: PASS"; then
    echo "PASS" >"${CODEBASE_CACHE}"
    printf 'codebase: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Codebase review passed"

    # Extract and file non-blocking issues (best-effort, never blocks)
    if echo "${CODEBASE_OUTPUT}" | grep -q "NON_BLOCKING_ISSUE:"; then
      log_info "Filing non-blocking issues found during codebase review..."
      create_nonblocking_issues "${CODEBASE_OUTPUT}" || true
    fi

    exit 0
  elif echo "${CODEBASE_OUTPUT}" | grep -q "VERDICT: FAIL"; then
    if echo "${CODEBASE_OUTPUT}" | grep -q "SEVERITY: BLOCKING"; then
      printf 'codebase: FAIL (blocking)\n' >>"${REVIEW_LOG}" || true
      log_error "Codebase review found blocking issues"
      exit 1
    else
      printf 'codebase: FAIL (warnings only)\n' >>"${REVIEW_LOG}" || true
      log_warn "Codebase review found warnings (non-blocking)"
      exit 0
    fi
  else
    log_error "Could not parse codebase review verdict"
    log_error "Output was:"
    echo "${CODEBASE_OUTPUT}" | head -20 >&2
    printf 'codebase: FAIL (unparseable)\n' >>"${REVIEW_LOG}" || true
    exit 1
  fi
fi

# --- Detect when adversarial review is warranted ---
# EXPANDED: More aggressive detection - extra review time beats CI cycles
detect_security_critical() {
  local files
  files=$(git diff --cached --name-only 2>/dev/null || echo "")

  # Path-based patterns (primary detection) - SIGNIFICANTLY EXPANDED
  # Philosophy: Better to over-review than under-review
  local path_patterns=(
    # Authentication & Authorization
    'auth|oauth|jwt|password|session|login|register|signin|signup|sso|saml|ldap|credential|token'
    # Payment & Financial
    'payment|billing|stripe|paypal|checkout|transaction|invoice|subscription|pricing|cart|order'
    # Database & Data
    'db|database|model|migration|schema|query|sql|orm|prisma|sequelize|typeorm|repository|entity'
    # Security & Cryptography
    'security|crypto|encryption|secret|vault|key|certificate|hash|cipher'
    # API & External Services
    'api|webhook|endpoint|middleware|interceptor|gateway|route|controller|handler'
    # User Data & Privacy
    'user|account|profile|permission|role|access|admin|privilege|member'
    # Configuration & Infrastructure
    'config|env|environment|setting|\.env|secret|credential'
    # State Management (often security-sensitive)
    'store|state|reducer|context|provider'
    # Forms & Input (validation, injection risks)
    'form|input|validate|sanitize|filter'
    # File Operations (path traversal, uploads)
    'file|upload|download|storage|asset|media'
    # Network & Communication
    'http|fetch|axios|request|socket|websocket|sse'
    # Testing (ensure security tests exist)
    'test|spec|\.test\.|\.spec\.'
  )

  local combined_pattern
  combined_pattern=$(printf '%s|' "${path_patterns[@]}")
  combined_pattern="${combined_pattern%|}" # Remove trailing |

  if echo "${files}" | grep -qiE "(${combined_pattern})"; then
    return 0 # Warrants adversarial review
  fi

  # Content-based detection (scan diff for sensitive patterns)
  local content_patterns=(
    # Secrets & Keys
    'API_KEY|SECRET_KEY|PRIVATE_KEY|ACCESS_TOKEN|REFRESH_TOKEN|BEARER|PASSWORD'
    # Auth patterns
    'bcrypt|argon2|pbkdf2|authenticate|authorize|permission|isAdmin|hasRole'
    # Payment
    'stripe|paypal|braintree|credit.?card|payment.?intent|charge'
    # Database queries
    'SELECT|INSERT|UPDATE|DELETE|DROP|CREATE TABLE|ALTER TABLE|query\(|execute\('
    # Security functions
    'encrypt|decrypt|hash|salt|nonce|cipher|sign|verify'
    # Dangerous patterns (injection risks)
    'eval\(|exec\(|system\(|shell_exec|child_process|subprocess|dangerouslySetInnerHTML'
    # File operations
    'readFile|writeFile|unlink|rmdir|chmod|chown|createReadStream|createWriteStream'
    # Network
    'fetch\(|axios\.|http\.|https\.|request\(|\.get\(|\.post\(|\.put\(|\.delete\('
    # Environment variables
    'process\.env|import\.meta\.env|getenv|os\.environ'
    # Error handling (often reveals sensitive info)
    'catch\s*\(|\.catch\(|try\s*{|throw\s+new'
  )

  local content_pattern
  content_pattern=$(printf '%s|' "${content_patterns[@]}")
  content_pattern="${content_pattern%|}"

  if echo "${DIFF}" | grep -qiE "(${content_pattern})"; then
    return 0 # Warrants adversarial review
  fi

  # File extension check - certain extensions always warrant scrutiny
  if echo "${files}" | grep -qiE '\.(sql|env|key|pem|crt|p12|pfx|jks)$'; then
    return 0
  fi

  # Size-based heuristic: Larger changes warrant more scrutiny
  local line_count
  line_count=$(echo "${DIFF}" | wc -l | tr -d ' ')
  if [[ ${line_count} -gt 200 ]]; then
    return 0 # Large changes warrant adversarial review
  fi

  return 1 # Doesn't need adversarial review
}

IS_SECURITY_CRITICAL=false
if detect_security_critical; then
  IS_SECURITY_CRITICAL=true
fi

# --- Agent-Based Review Flow ---

# Build cache keys
CODE_REVIEWER_CACHE="${CACHE_DIR}/code-reviewer-${DIFF_HASH}"
ADVERSARIAL_CACHE="${CACHE_DIR}/adversarial-${DIFF_HASH}"

# Build structured prompt for agents
# Use string concatenation - safe variable expansion without command execution
AGENT_PROMPT="You are performing a pre-commit code review. Analyze the diff below and identify issues BEFORE code is committed.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[If FAIL, list each issue:]
ISSUE: [one-line description]
SEVERITY: [BLOCKING or WARNING]
LOCATION: [file:line]
DETAILS: [explanation and fix]

[If PASS:]
No blocking issues found.

Review this diff:

\`\`\`diff
${DIFF}
\`\`\`"

# Announce log path BEFORE any agent runs — this line IS visible in Claude Code's
# Bash tool even when subsequent output is swallowed by the nested claude process.
printf 'diff_lines: %d\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true
log_info "Review log: ${REVIEW_LOG}"

# Step 1: Run code-reviewer (always)
# || true: invoke_agent may return 1 on transient CLI failure; set -e must not kill the script.
# Errors surface as "VERDICT: FAIL (agent error: N)" in output and are handled below.
CODE_REVIEWER_OUTPUT=$(invoke_agent "code-reviewer" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}") || true
# Guard: invoke_agent may exit 0 but produce no output (silent agent failure).
# Normalise to a transient-error verdict so the non-blocking check below handles it.
[[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

# Parse verdict from output (errors produce "VERDICT: FAIL (agent error: ...)")
if echo "${CODE_REVIEWER_OUTPUT}" | grep -q "VERDICT: PASS"; then
  CODE_REVIEWER_VERDICT="PASS"
elif echo "${CODE_REVIEWER_OUTPUT}" | grep -q "VERDICT: FAIL"; then
  CODE_REVIEWER_VERDICT="FAIL"
else
  log_error "Could not parse code-reviewer verdict"
  log_error "BLOCKING: Cannot verify review result"
  log_error ""
  log_error "Output was:"
  echo "${CODE_REVIEWER_OUTPUT}" | head -20 >&2
  exit 1
fi

# Step 2: Run adversarial-reviewer (always)
# The adversarial-reviewer runs on every commit alongside code-reviewer.
# Security-critical detection is still logged for informational purposes.
ADVERSARIAL_OUTPUT=""
ADVERSARIAL_VERDICT="N/A"

if [[ "${IS_SECURITY_CRITICAL}" == true ]]; then
  log_info "Security-critical files detected — adversarial review has elevated scrutiny"
fi

# Check if adversarial-reviewer agent exists
if ! find -L "${HOME}/.claude/plugins/marketplaces" -name "adversarial-reviewer.md" -type f 2>/dev/null | grep -q .; then
  log_warn "adversarial-reviewer agent not found - skipping (see ~/.claude/docs/CUSTOM_AGENTS.md for setup)"
  ADVERSARIAL_VERDICT="N/A"
else
  # || true: same set -e guard as code-reviewer above
  ADVERSARIAL_OUTPUT=$(invoke_agent "adversarial-reviewer" "${AGENT_PROMPT}" "${ADVERSARIAL_CACHE}") || true
  # Guard: same silent-failure normalisation as code-reviewer above
  [[ -n "${ADVERSARIAL_OUTPUT}" ]] || ADVERSARIAL_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

  if echo "${ADVERSARIAL_OUTPUT}" | grep -q "VERDICT: PASS"; then
    ADVERSARIAL_VERDICT="PASS"
  elif echo "${ADVERSARIAL_OUTPUT}" | grep -q "VERDICT: FAIL"; then
    ADVERSARIAL_VERDICT="FAIL"
  else
    log_error "Could not parse adversarial-reviewer verdict"
    log_error "BLOCKING: Cannot verify adversarial review result"
    log_error ""
    log_error "Output was:"
    echo "${ADVERSARIAL_OUTPUT}" | head -20 >&2
    exit 1
  fi
fi

# --- Evaluate Combined Verdict ---
echo "" >&2

# Show code-reviewer output; also write to log (best-effort: || true guards set -e)
echo "=== CODE REVIEWER ===" >&2
echo "${CODE_REVIEWER_OUTPUT}" >&2
echo "" >&2
{ printf '=== CODE REVIEWER ===\n%s\n' "${CODE_REVIEWER_OUTPUT}"; } >>"${REVIEW_LOG}" || true

# Show adversarial-reviewer output if ran
if [[ -n "${ADVERSARIAL_OUTPUT}" ]]; then
  echo "=== ADVERSARIAL REVIEWER ===" >&2
  echo "${ADVERSARIAL_OUTPUT}" >&2
  echo "" >&2
  { printf '=== ADVERSARIAL REVIEWER ===\n%s\n' "${ADVERSARIAL_OUTPUT}"; } >>"${REVIEW_LOG}" || true
fi

# Write verdict summary before exit — EXIT trap appends exit_code
{
  printf 'code-reviewer: %s\n' "${CODE_REVIEWER_VERDICT}"
  printf 'adversarial-reviewer: %s\n' "${ADVERSARIAL_VERDICT}"
} >>"${REVIEW_LOG}" || true

# Determine final result
if [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" ]]; then
  # Check if BLOCKING severity exists
  if echo "${CODE_REVIEWER_OUTPUT}" | grep -q "SEVERITY: BLOCKING"; then
    log_error "code-reviewer found blocking issues - commit rejected"
    exit 1
  else
    log_warn "code-reviewer found warnings (non-blocking)"
    # Continue to adversarial if security-critical
  fi
fi

if [[ "${ADVERSARIAL_VERDICT}" == "FAIL" ]]; then
  # Transient infrastructure failures (timeout, CLI crash) produce "VERDICT: FAIL (timeout)"
  # or "VERDICT: FAIL (agent error: N)" with no SEVERITY: BLOCKING — treat as non-blocking,
  # consistent with how code-reviewer handles the same case.
  if echo "${ADVERSARIAL_OUTPUT}" | grep -qE "VERDICT: FAIL \((timeout|agent error)"; then
    log_warn "adversarial-reviewer timed out or errored — non-blocking (infrastructure failure)"
  else
    log_error "adversarial-reviewer found issues - commit rejected"
    log_error "Note: code-reviewer passed but adversarial-reviewer caught additional concerns"
    exit 1
  fi
fi

# Defensive: block on any unexpected verdict values
# (code-reviewer parsing already exits 1 on failure, so this should never trigger)
if [[ "${CODE_REVIEWER_VERDICT}" != "PASS" && "${CODE_REVIEWER_VERDICT}" != "FAIL" ]]; then
  log_error "Unexpected code-reviewer verdict: ${CODE_REVIEWER_VERDICT}"
  exit 1
fi
if [[ "${ADVERSARIAL_VERDICT}" != "PASS" && "${ADVERSARIAL_VERDICT}" != "FAIL" && "${ADVERSARIAL_VERDICT}" != "N/A" ]]; then
  log_error "Unexpected adversarial-reviewer verdict: ${ADVERSARIAL_VERDICT}"
  exit 1
fi

# All checks passed
if [[ "${ADVERSARIAL_VERDICT}" != "N/A" ]]; then
  log_success "Review passed (code-reviewer + adversarial-reviewer)"
else
  log_success "Review passed (code-reviewer)"
fi
_review_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ || true)
# Overwrite the start timestamp (first line) with the completion timestamp so that
# `head -1 ~/.claude/last-review-result.log` reflects when the review FINISHED,
# not when it started. For slow reviews (>60s), this prevents false staleness alerts.
{
  printf '%s\n' "${_review_ts}"
  tail -n +2 "${REVIEW_LOG}"
} >"${REVIEW_LOG}.tmp" \
  && mv "${REVIEW_LOG}.tmp" "${REVIEW_LOG}" || true
# Also update the global pointer's timestamp to match the completion time.
# Controllers checking head -1 ~/.claude/last-review-result.log need the
# completion time (not start time) for the staleness check to be accurate.
# Write all fields from current session variables (not tail -n +2 of the
# existing file) to avoid a read-modify-write race with concurrent sessions.
{
  printf '%s\n' "${_review_ts}"
  printf 'repo: %s\n' "${_review_repo}"
  printf 'branch: %s\n' "${_review_branch}"
  printf 'commit: %s\n' "${_review_commit}"
  printf 'log: %s\n' "${REVIEW_LOG}"
} >"${_global_log}.tmp" \
  && mv "${_global_log}.tmp" "${_global_log}" || true
log_success "Review timestamp: ${_review_ts}  ← verify this matches commit time"
exit 0
