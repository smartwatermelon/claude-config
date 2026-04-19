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

# Responsiveness check: if the CLI is hung, each agent invocation below
# burns TIMEOUT_SECONDS (120-300s) before failing. A --version call should
# return within a few seconds; if `timeout` has to kill it (exit 124), the
# CLI is hung — fail fast so the caller can diagnose instead of waiting
# through multiple long timeouts.
#
# Note: we ONLY fail on exit 124 (timeout). A CLI that responds with any
# other nonzero status (broken install, auth expired, etc.) is still
# responsive — let the real invocation surface the actionable error. Mock
# CLIs in the test suite exit with configured codes; those must not trip
# this preflight. See hooks/tests/run-review-test.sh.
_preflight_rc=0
timeout 5 "${CLAUDE_CLI}" --version >/dev/null 2>&1 || _preflight_rc=$?
if [[ ${_preflight_rc} -eq 124 ]]; then
  log_error "Claude CLI did not respond to --version within 5s: ${CLAUDE_CLI}"
  log_error "CLI may be hung. Diagnose:"
  log_error "  timeout 5 ${CLAUDE_CLI} --version"
  exit 1
fi
unset _preflight_rc

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

  # Parallel dispatch: up to CHUNK_PARALLEL claude invocations in flight.
  # Each subshell writes its result (file path on line 1, agent output from
  # line 2 onwards) to a unique file under _chunk_results. Aggregation runs
  # serially after `wait`. Bound prevents pathological diffs (50 files)
  # from launching 50 concurrent claude processes.
  local CHUNK_PARALLEL
  CHUNK_PARALLEL=$(git config --get --type=int review.chunkParallel 2>/dev/null || echo "4")
  # Not `local`: the EXIT trap references this by name for cleanup on
  # abnormal exit (SIGINT while the function is on the call stack). Bash's
  # visibility of function-local variables to traps is implementation-
  # dependent, so keep this at script scope where the trap can always see
  # it. On the normal return path the in-function `rm -rf` below still
  # handles cleanup; the trap is the backstop for SIGINT / errexit.
  # Issue #130.
  _chunk_results=$(mktemp -d)
  local -a _chunk_pids=()

  # Dispatch phase: build per-file prompt, spawn background invoke_agent.
  # Skip-if-too-large is still serial (and bumps skipped_files directly).
  while IFS= read -r file; do
    [[ -z "${file}" ]] && continue

    local file_diff
    file_diff=$(git diff --cached -U10 -- "${file}" 2>/dev/null || echo "")
    [[ -z "${file_diff}" ]] && continue

    local file_lines
    file_lines=$(echo "${file_diff}" | wc -l | tr -d ' ')

    if [[ ${file_lines} -gt ${REVIEW_CHUNK_SIZE} ]]; then
      log_warn "Skipping ${file} (${file_lines} lines > ${REVIEW_CHUNK_SIZE} chunk size)"
      ((skipped_files += 1))
      continue
    fi

    # Bounded concurrency: reap finished pids, sleep if still at cap.
    while [[ ${#_chunk_pids[@]} -ge ${CHUNK_PARALLEL} ]]; do
      local -a _alive_pids=()
      local _p
      for _p in "${_chunk_pids[@]}"; do
        if kill -0 "${_p}" 2>/dev/null; then
          _alive_pids+=("${_p}")
        fi
      done
      _chunk_pids=("${_alive_pids[@]}")
      [[ ${#_chunk_pids[@]} -lt ${CHUNK_PARALLEL} ]] || sleep 0.1
    done

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

    # Create per-file cache key. Includes SCRIPT_SHA so prompt/logic edits
    # invalidate stale PASS entries (see DIFF_HASH above for rationale).
    local file_cache_key
    # Use `shasum -a 256` (BSD) rather than `sha256sum` (GNU-only) so the cache
    # works on macOS by default. Previously this fell to the "nocache" fallback
    # on every Darwin host unless the user had installed GNU coreutils, which
    # silently disabled per-file chunked caching. Matches the DIFF_HASH tool
    # choice elsewhere in this file. Issue #126.
    file_cache_key=$(printf '%s\n%s\n' "${SCRIPT_SHA:-nover}" "${file_diff}" | shasum -a 256 2>/dev/null | awk '{print $1}' || echo "nocache")
    [[ -n "${file_cache_key}" ]] || file_cache_key="nocache"
    local file_cache="${CACHE_DIR}/${file//\//_}_${file_cache_key}"

    # Sanitize file path to a safe filename for the result file.
    local _safe_name="${file//\//__}"
    _safe_name="${_safe_name// /_}"

    # Background dispatch. Each subshell captures invoke_agent stdout;
    # stderr (progress lines) flows through to the user's terminal. Empty
    # output on agent error is normalized here so the aggregate loop can
    # treat it uniformly.
    (
      _fout=$(invoke_agent "code-reviewer" "${file_prompt}" "${file_cache}") || true
      [[ -n "${_fout}" ]] || _fout="VERDICT: FAIL (agent error: invoke_agent produced no output)"
      {
        printf '%s\n' "${file}"
        printf '%s\n' "${_fout}"
      } >"${_chunk_results}/${_safe_name}"
    ) &
    _chunk_pids+=("$!")
  done <<<"${files}"

  # Wait for all remaining background jobs.
  wait 2>/dev/null || true

  # Aggregate phase: walk per-file results in the original git-diff file
  # order (so the issues_output digest is deterministic and matches the
  # pre-parallel serial order, not alphabetic-by-sanitized-name). Runs
  # serially on the main shell so accumulator updates are safe.
  local _result_file _rfile _rout _agg_safe
  while IFS= read -r _rfile; do
    [[ -z "${_rfile}" ]] && continue
    _agg_safe="${_rfile//\//__}"
    _agg_safe="${_agg_safe// /_}"
    _result_file="${_chunk_results}/${_agg_safe}"
    [[ -f "${_result_file}" ]] || continue
    _rout=$(tail -n +2 "${_result_file}")

    # Synthetic transient-failure verdicts (timeout or agent error) indicate
    # the agent failed — skip the file rather than counting it as a blocking
    # issue. Matches the prior serial behavior where agent_exit != 0 always
    # incremented skipped_files. invoke_agent emits either "(timeout)" or
    # "(agent error: N)"; real content failures produce a bare "VERDICT: FAIL"
    # followed by SEVERITY/ISSUE/LOCATION lines with no parens on the verdict.
    # Match any "VERDICT: FAIL (" (parenthesis-suffixed) to catch both.
    if echo "${_rout}" | grep -q "VERDICT: FAIL ("; then
      log_warn "Agent timeout/error for ${_rfile} - skipping this file"
      ((skipped_files += 1))
      continue
    fi

    if echo "${_rout}" | grep -q "VERDICT: FAIL"; then
      if echo "${_rout}" | grep -q "SEVERITY: BLOCKING"; then
        ((blocking_count += 1))
        overall_verdict="FAIL"
      else
        ((warning_count += 1))
      fi

      issues_output="${issues_output}

=== Issues in ${_rfile} ===
${_rout}"
    fi

    ((reviewed_files += 1))
  done <<<"${files}"

  rm -rf "${_chunk_results}"
  unset _chunk_results _chunk_pids

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
trap '_ec=$?; rm -rf "${_chunk_results:-}" 2>/dev/null; rm -f "${_cr_out:-}" "${_ar_out:-}" 2>/dev/null; [[ -n "${REVIEW_LOG:-}" ]] && printf "exit_code: %d\n" "$_ec" >> "${REVIEW_LOG}" || true' EXIT

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

# Cache key includes the hash of THIS script so edits to review logic or
# prompt text automatically invalidate stale PASS entries. Without this,
# a tightened adversarial prompt would read old PASS cache for identical
# diffs and silently skip the stricter review. Fail open on shasum miss
# (falls back to diff-only hash) so cache still works in stripped envs.
SCRIPT_SHA=$(shasum -a 256 "${BASH_SOURCE[0]}" 2>/dev/null | awk '{print $1}' | cut -c1-12 || echo "nover")
DIFF_HASH=$(printf '%s\n%s\n' "${SCRIPT_SHA}" "${DIFF}" | shasum -a 256 | awk '{print $1}')
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

elif [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt ${REVIEW_MAX_LINES} ]]; then
  # Medium diff (commit-mode only) — use chunked review.
  # full-diff and codebase modes have their own dedicated handlers below
  # (lines 582+ and 672+) and are INTENDED for large cross-file analysis.
  # Routing them to chunked here would bypass their dedicated prompts
  # whenever the feature-branch diff exceeds REVIEW_MAX_LINES, defeating
  # their purpose. Issue #127.
  log_warn "Diff is large (${DIFF_LINES} lines), using chunked file-by-file review"
  printf 'diff_lines: %d (chunked review)\n' "${DIFF_LINES}" >>"${REVIEW_LOG}" || true
  perform_chunked_review "${DIFF_LINES}"
  exit $? # Exit with chunked review result

elif [[ "${REVIEW_MODE}" != "full-diff" && "${REVIEW_MODE}" != "codebase" ]] && [[ ${DIFF_LINES} -gt $((REVIEW_MAX_LINES * 3 / 4)) ]]; then
  # Approaching limit (commit mode) — warn but proceed with full review.
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

# --- Check for documentation-only / lockfile-only changes (commit mode only) ---
# These short-circuits compare staged-index file names against skip-eligible
# patterns. In --mode=full-diff and --mode=codebase the real diff source is
# stdin (piped main...HEAD), NOT the staged index; the staged index may be
# markdown-only while the branch's piped diff contains code. Skipping based
# on the wrong source silently bypasses the full-branch review those modes
# are designed for. Commit-mode DIFF is piped from `git diff --cached` so
# staged index aligns with the review input — the short-circuits are safe
# only there. Issue #131.
#
# Derive CHANGED_FILES outside the guard so it's defined (empty) in other
# modes; the two checks below are both no-ops when unset.
CHANGED_FILES=""
if [[ "${REVIEW_MODE}" == "commit" ]]; then
  CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || echo "")
fi

# Skip code review for markdown files - they're handled by markdownlint
if [[ -n "${CHANGED_FILES}" ]]; then
  # Check if ALL changed files are markdown
  NON_MD_FILES=$(echo "${CHANGED_FILES}" | grep -vE '\.md$' || echo "")
  if [[ -z "${NON_MD_FILES}" ]]; then
    log_info "Markdown-only changes detected - skipping code review (handled by markdownlint)"
    printf 'skipped: markdown-only\n' >>"${REVIEW_LOG}" || true
    exit 0
  fi
fi

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

# --- Agent-Based Review Flow ---
# Both code-reviewer and adversarial-reviewer run on every commit regardless
# of content. The prior detect_security_critical heuristic (~90 lines of
# regex patterns matching paths/content/extensions) was removed because its
# only consumer was a single log_info — it never changed reviewer behavior,
# prompt content, or cache policy. If differentiated scrutiny is ever
# needed, wire it with intent (different prompt, different timeout, or
# separate cache bucket) instead of resurrecting the dead heuristic.

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

# Run code-reviewer and adversarial-reviewer in parallel when both are
# available. Each reviewer's stdout is captured to its own temp file so
# the outputs don't interleave. stderr (log_info progress lines) flows
# through to the user's terminal — it may interleave between the two
# agents but remains readable because each log line is agent-prefixed.
#
# Parallelization roughly halves wall time on the common two-agent path
# (previously serial at 60-120s each; now both run concurrently).
#
# Serial fallback: when adversarial-reviewer isn't installed, only
# code-reviewer runs (unchanged from the prior serial behavior).

ADVERSARIAL_OUTPUT=""
ADVERSARIAL_VERDICT="N/A"
ADVERSARIAL_AVAILABLE=true
if ! find -L "${HOME}/.claude/plugins/marketplaces" -name "adversarial-reviewer.md" -type f 2>/dev/null | grep -q .; then
  log_warn "adversarial-reviewer agent not found - skipping (see ~/.claude/docs/CUSTOM_AGENTS.md for setup)"
  ADVERSARIAL_AVAILABLE=false
fi

if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  _cr_out=$(mktemp)
  _ar_out=$(mktemp)
  # Subshells inherit set -e. invoke_agent handles its own errors and always
  # echoes a verdict line (real output, or synthetic "VERDICT: FAIL (agent
  # error/timeout)"). `|| true` on the wait calls suppresses propagation of
  # the subshell's exit status; the same empty-output guard below handles
  # any silent failure.
  (invoke_agent "code-reviewer" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}" >"${_cr_out}") &
  _cr_pid=$!
  (invoke_agent "adversarial-reviewer" "${AGENT_PROMPT}" "${ADVERSARIAL_CACHE}" >"${_ar_out}") &
  _ar_pid=$!
  wait "${_cr_pid}" || true
  wait "${_ar_pid}" || true
  CODE_REVIEWER_OUTPUT=$(cat "${_cr_out}")
  ADVERSARIAL_OUTPUT=$(cat "${_ar_out}")
  rm -f "${_cr_out}" "${_ar_out}"
  unset _cr_out _ar_out _cr_pid _ar_pid
else
  # Serial path (no adversarial): only code-reviewer runs.
  CODE_REVIEWER_OUTPUT=$(invoke_agent "code-reviewer" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}") || true
fi

# Guard: invoke_agent may exit 0 but produce no output (silent agent failure).
# Normalise to a transient-error verdict so the non-blocking check below handles it.
[[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  [[ -n "${ADVERSARIAL_OUTPUT}" ]] || ADVERSARIAL_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
fi

# Parse verdict from code-reviewer output
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

# Parse verdict from adversarial-reviewer output (when available)
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
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
