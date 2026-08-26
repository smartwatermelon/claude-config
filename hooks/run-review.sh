#!/usr/bin/env bash
set -euo pipefail
unset CDPATH

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
# FLAGS:
#   --mode=full-diff | --mode=codebase
#       Switch review mode (default: commit / pre-commit).
#   --message-file=PATH | --message-file PATH
#       Read the commit message from PATH instead of $GIT_DIR/COMMIT_EDITMSG.
#       Used by the commit-msg hook to inject the actual in-progress
#       message; pre-commit hooks cannot read the message because git
#       has not yet written it to COMMIT_EDITMSG at pre-commit time
#       (per `man githooks`: pre-commit "is invoked before obtaining
#       the proposed commit log message"). When this flag is absent,
#       behavior is unchanged.
#
# EXIT CODES:
#   0 = Review passed (no blocking issues)
#   1 = Review failed (issues found or error)
#
# CONFIGURATION (via git config):
#   review.maxLines        - Max lines for full review (default: 1000)
#   review.skipThreshold   - Skip AI review beyond this (default: 2500)
#   review.chunkSize       - Max lines per file in chunked mode (default: 800)
#   review.model           - Claude model ID for code-reviewer (default: haiku for commits, sonnet for full-diff/codebase)
#   review.adversarialModel - Claude model ID for adversarial-reviewer (default: claude-sonnet-4-6, always, regardless of mode)
#   review.arbiterModel    - Claude model ID for the reconciliation arbiter
#                             (default: claude-sonnet-4-6, only invoked when
#                             code-reviewer BLOCKING FAIL disagrees with an
#                             adversarial-reviewer PASS)
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

# Dry-run: run the review exactly as a real run, but print non-blocking
# findings to stdout instead of filing them. Set by --no-file or by
# REVIEW_NO_FILE=1 in the environment.
#
# This exists so reading findings before they become issues does not require
# stubbing `gh` from outside on PATH. A blanket gh stub also breaks the
# reviewer's own environment probes (_repo_has_issues_enabled, repo-owner
# detection), so a stubbed run is not guaranteed to be the same review as a
# real one; this flag suppresses only the filing step. See #415.
REVIEW_NO_FILE="${REVIEW_NO_FILE:-}"

# Progressive review configuration (with git config overrides)
REVIEW_MAX_LINES=$(git config --get --type=int review.maxLines 2>/dev/null || echo "1000")
REVIEW_SKIP_THRESHOLD=$(git config --get --type=int review.skipThreshold 2>/dev/null || echo "2500")
REVIEW_CHUNK_SIZE=$(git config --get --type=int review.chunkSize 2>/dev/null || echo "800")

# --- Mode ---
REVIEW_MODE="commit"  # default: pre-commit review (code-reviewer + adversarial)
# --- Optional commit-message override ---
# When set, _read_commit_message reads from this path instead of the
# default per-mode source. Wired by the commit-msg hook so the reviewer
# sees the actual in-progress message (pre-commit cannot do this — see
# header comment block above and `man githooks`).
MESSAGE_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode=full-diff) REVIEW_MODE="full-diff" ;;
    --mode=codebase) REVIEW_MODE="codebase" ;;
    --mode=*) echo "Unknown mode: $1" >&2; exit 1 ;;
    --no-file) REVIEW_NO_FILE=1 ;;
    --message-file=*) MESSAGE_FILE="${1#*=}" ;;
    --message-file)
      # Space-form: consume value as $2, then shift past it. We do NOT inner-
      # shift first and then rely on the outer shift, because if the flag was
      # the LAST argument with no value (`--message-file` alone), the outer
      # shift would fail with "shift count out of range" under set -e and
      # abort the script. `${2:-}` safely returns "" when $2 is unset.
      MESSAGE_FILE="${2:-}"
      [[ $# -ge 2 ]] && shift
      ;;
  esac
  shift
done

# Override timeout for codebase mode (longer due to tool-access exploration)
if [[ "${REVIEW_MODE}" == "codebase" ]]; then
  TIMEOUT_SECONDS=$(git config --get --type=int review.codebaseTimeout 2>/dev/null || echo "300")
fi

# --- Model selection ---
# Priority: git config review.model > mode-based default > CLI default
# Haiku for commit-level (small diffs, fast feedback); Sonnet for branch/codebase analysis.
# This REVIEW_MODEL / CODE_REVIEWER_MODEL_ARGS pair governs code-reviewer (and,
# in full-diff/codebase mode, the single reviewer invocation issued there —
# see ADVERSARIAL_MODEL_ARGS below for why those specific call sites use the
# adversarial model instead).
REVIEW_MODEL=$(git config --get review.model 2>/dev/null || echo "")
if [[ -z "${REVIEW_MODEL}" ]]; then
  case "${REVIEW_MODE}" in
    commit)   REVIEW_MODEL="claude-haiku-4-5-20251001" ;;
    full-diff) REVIEW_MODEL="claude-sonnet-4-6" ;;
    codebase) REVIEW_MODEL="claude-sonnet-4-6" ;;
    *)        REVIEW_MODEL="" ;;
  esac
fi
CODE_REVIEWER_MODEL_ARGS=()
if [[ -n "${REVIEW_MODEL}" ]]; then
  CODE_REVIEWER_MODEL_ARGS=(--model "${REVIEW_MODEL}")
fi

# adversarial-reviewer gets its own model, independent of REVIEW_MODE.
# code-reviewer's mechanical issue-spotting is a legitimate Haiku task, but
# adversarial-reviewer's assume-wrong-until-proven reasoning benefits from a
# bigger model even on the highest-frequency path (commit mode) — see issue
# #235. Override via `git config review.adversarialModel <model-id>`.
ADVERSARIAL_MODEL=$(git config --get review.adversarialModel 2>/dev/null || echo "")
[[ -n "${ADVERSARIAL_MODEL}" ]] || ADVERSARIAL_MODEL="claude-sonnet-4-6"
ADVERSARIAL_MODEL_ARGS=(--model "${ADVERSARIAL_MODEL}")

# Arbiter model: used only when code-reviewer and adversarial-reviewer
# disagree (BLOCKING FAIL vs PASS) in commit mode. Defaults to the same
# model as adversarial-reviewer since both need the bigger-model reasoning
# the disagreement itself signals is warranted.
ARBITER_MODEL=$(git config --get review.arbiterModel 2>/dev/null || echo "")
[[ -n "${ARBITER_MODEL}" ]] || ARBITER_MODEL="claude-sonnet-4-6"
ARBITER_MODEL_ARGS=(--model "${ARBITER_MODEL}")

# --- Reviewer agent selection ---
# Pinned to a fully-qualified plugin:agent name (git config review.codeReviewerAgent
# to override). The bare name "code-reviewer" broke once a second installed plugin
# also shipped an agent literally named "code-reviewer" — Claude CLI refuses
# ambiguous bare names, so every commit's code-reviewer pass silently errored
# (non-blocking, but useless). The installed agent ID doubles the plugin name —
# comprehensive-review:comprehensive-review-code-reviewer — per the
# comprehensive-review plugin's agents/code-reviewer.md frontmatter; verify with
# `claude --agent bogus -p` (its "Available agents" error lists the real IDs).
# adversarial-reviewer stays a bare name since it is still unique (lives only in
# the local code-critic marketplace, see CUSTOM_AGENTS.md).
CODE_REVIEWER_AGENT=$(git config --get review.codeReviewerAgent 2>/dev/null || echo "comprehensive-review:comprehensive-review-code-reviewer")

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

# Normalize an agent's VERDICT line into a bare token, tolerant of markdown
# emphasis (**PASS**, `PASS`, _PASS_), case, and spacing that would defeat a
# literal `grep "VERDICT: PASS"`. Echoes PASS | FAIL | REVISE | "" (unparseable).
# Preserves the original "PASS anywhere wins" precedence. Transient markers such
# as "VERDICT: FAIL (timeout)" still normalize to FAIL; callers that must
# distinguish those re-inspect the raw output separately.
parse_verdict() {
  local _norm
  _norm=$(printf '%s\n' "$1" | tr -d '*`_')
  if printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*PASS'; then
    echo "PASS"
  elif printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*FAIL'; then
    echo "FAIL"
  elif printf '%s\n' "${_norm}" | grep -qiE 'VERDICT:[[:space:]]*REVISE'; then
    echo "REVISE"
  else
    echo ""
  fi
}

# --- Version-pin-unfamiliarity downgrade ---
# Rationale and rules: docs/CODE-REVIEW.md
# §Version-Pin Unfamiliarity Is Not a Blocking Finding
#
# Reviewer models' training data has a cutoff; a manifest pin for a tool
# version newer than that cutoff reads to the reviewer as "this version
# doesn't exist" or "I don't recognize this" — a false BLOCKING FAIL on
# code that was tested and pinned deliberately. Treat that specific
# objection as invalid and downgrade it to WARNING, without per-ecosystem
# manifest parsing and without a separate test-evidence check (tests-passed
# is already assumed by Protocol 3 by the time a diff reaches review).
#
# What this function does NOT do, deliberately (YAGNI):
#   - It does not verify the pin against a package registry.
#   - It does not distinguish package.json from go.mod from Gemfile, etc.
#   - It does not trust the reviewer's own "I don't recognize this" claim
#     at face value — it re-classifies the DETAILS/ISSUE text itself, so
#     a reviewer that mislabels a real CVE finding as "unfamiliar" still
#     gets caught by the known-bad pattern below.
#
# $1 = raw reviewer output (VERDICT/ISSUE/SEVERITY/LOCATION/DETAILS blocks)
# Prints the same text with qualifying BLOCKING lines rewritten to WARNING.
# If that leaves no BLOCKING severity anywhere, the leading VERDICT: FAIL /
# REVISE is rewritten to PASS as well — parse_verdict reads only the VERDICT
# line, so without this the downgrade would relabel the issue while still
# blocking the commit, which is the opposite of the intent.
# Emits one log_warn per downgrade (stderr) so it stays visible, matching
# how arbitration disagreements are logged elsewhere in this file.
downgrade_version_unfamiliarity_findings() {
  local _output="$1"
  local -a _out_lines=()
  local -a _block=()
  local _line _block_text _is_blocking _tool_hint _result
  local _tool_version _issue_title
  local _downgraded="no"

  # Language that indicates the reviewer's sole objection is "I don't
  # recognize this version" (unfamiliarity), as opposed to a substantive
  # claim about the version being bad. Case-insensitive.
  local _unfamiliar_re='does not exist|doesn.?t exist|no such version|not aware of|unfamiliar|do not recognize|don.?t recognize|unrecognized version|not a (real|valid|known) version|nonexistent version'

  # Language that indicates a substantive, non-familiarity objection.
  # If this matches anywhere in the block, the block is NEVER downgraded,
  # even if unfamiliarity language also appears — a known-bad claim wins.
  # The dot in `supply.chain` is an intentional wildcard, not an unescaped
  # literal: it covers "supply chain", "supply-chain", and "supply_chain".
  # Do not "correct" it to `supply\.chain`.
  local _knownbad_re='CVE-|CVE[[:space:]]|vulnerab|RCE|exploit|deprecat|yanked|breaking change|incompatib|security advisory|malicious|supply.chain'

  # Walk the output one ISSUE:-delimited block at a time. Each block runs
  # from an "ISSUE:" line up to (but not including) the next "ISSUE:" line
  # or end of input. Blocks are classified as a whole so DETAILS: text on
  # a later line still counts toward the block that owns it.
  _flush_block() {
    if [[ ${#_block[@]} -eq 0 ]]; then
      return 0
    fi
    _block_text=$(printf '%s\n' "${_block[@]}")
    _is_blocking=$(printf '%s\n' "${_block_text}" | grep -qiE 'SEVERITY:[[:space:]]*BLOCKING' && echo yes || echo no)
    if [[ "${_is_blocking}" == "yes" ]] \
      && printf '%s\n' "${_block_text}" | grep -qiE "${_unfamiliar_re}" \
      && ! printf '%s\n' "${_block_text}" | grep -qiE "${_knownbad_re}"; then
      # Best-effort local corroboration: if a tool name is present and
      # invokable, log its installed version alongside the downgrade for
      # a human to sanity-check later. Not required to downgrade — an
      # absent local binary (an npm/pip package, say) is not a blocker.
      # grep -E has no lookahead, so match "<name> <version>" whole and strip
      # the version half with sed rather than trying to assert past it.
      _tool_hint=$(printf '%s\n' "${_block_text}" \
        | grep -oE '[a-zA-Z][a-zA-Z0-9_.-]{1,30}[[:space:]]+v?[0-9]+\.[0-9]' \
        | head -1 \
        | sed -E 's/[[:space:]]+v?[0-9]+\.[0-9].*$//' || true)
      if [[ -n "${_tool_hint}" ]] && command -v "${_tool_hint}" >/dev/null 2>&1; then
        _tool_version=$("${_tool_hint}" --version 2>/dev/null || true)
        _tool_version=$(printf '%s\n' "${_tool_version}" | head -1)
        [[ -n "${_tool_version}" ]] || _tool_version="unknown"
        log_warn "version-pin downgrade: local '${_tool_hint} --version' -> ${_tool_version}"
      fi
      _issue_title=$(printf '%s\n' "${_block_text}" | grep -im1 '^ISSUE:' || true)
      [[ -n "${_issue_title}" ]] || _issue_title="(untitled issue)"
      log_warn "Downgrading BLOCKING -> WARNING (version-pin unfamiliarity, not a known-bad claim): ${_issue_title}"
      _downgraded="yes"
      _block_text=$(printf '%s\n' "${_block_text}" | sed -E 's/^(SEVERITY:[[:space:]]*)BLOCKING/\1WARNING/I')
    fi
    _out_lines+=("${_block_text}")
    _block=()
  }

  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^ISSUE: ]]; then
      _flush_block
    fi
    _block+=("${_line}")
  done <<<"${_output}"
  _flush_block

  unset -f _flush_block

  if [[ ${#_out_lines[@]} -eq 0 ]]; then
    return 0
  fi

  _result=$(printf '%s\n' "${_out_lines[@]}")

  # Only promote the verdict when a downgrade actually happened AND nothing
  # blocking survives. A reviewer that raised an unrelated BLOCKING issue
  # alongside the version pin still fails, as it should.
  if [[ "${_downgraded}" == "yes" ]] \
    && ! printf '%s\n' "${_result}" | grep -qiE 'SEVERITY:[[:space:]]*BLOCKING'; then
    log_warn "All BLOCKING findings were version-pin unfamiliarity; promoting VERDICT to PASS"
    # awk, not `sed '1,/^VERDICT:/'`: that range ends at the SECOND match, so
    # it would rewrite a trailing VERDICT line too, and BSD sed ignores the
    # `0,/re/` form that would otherwise fix it. Rewrite the first line only.
    _result=$(printf '%s\n' "${_result}" | awk '
      BEGIN { done = 0 }
      !done && toupper($0) ~ /^VERDICT:[[:space:]]*(FAIL|REVISE)/ {
        # Rebuild rather than sub(): awk sub() is case-sensitive, so any
        # casing the toupper() guard admits ("verdict: revise", "fAiL")
        # would survive a substitution unchanged. parse_verdict is
        # case-insensitive, so that would still block the commit. Split on
        # the uppercased copy and keep the original tail verbatim.
        rest = $0
        sub(/^[^:]*:[[:space:]]*/, "", rest)
        upper = toupper(rest)
        keep = (upper ~ /^REVISE/) ? substr(rest, 7) : substr(rest, 5)
        print "VERDICT: PASS" keep
        done = 1
        next
      }
      { print }
    ')
  fi

  printf '%s\n' "${_result}"
}

# --- Shared issue library (for --mode=codebase non-blocking issues) ---
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-review-issues.sh
source "${_LIB_DIR}/lib-review-issues.sh"

# --- Shared context-assembly library (file-header extraction, round memory) ---
# shellcheck source=lib-review-context.sh
source "${_LIB_DIR}/lib-review-context.sh"

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
# Redirect stdin from /dev/null: the review diff arrives on this script's stdin
# (DIFF=$(cat) below), and a CLI/wrapper that reads stdin on --version would
# otherwise drain it, leaving DIFF empty ("No staged changes to review").
timeout 5 "${CLAUDE_CLI}" --version </dev/null >/dev/null 2>&1 || _preflight_rc=$?
if [[ ${_preflight_rc} -eq 124 ]]; then
  log_error "Claude CLI did not respond to --version within 5s: ${CLAUDE_CLI}"
  log_error "CLI may be hung. Diagnose:"
  log_error "  timeout 5 ${CLAUDE_CLI} --version"
  exit 1
fi
unset _preflight_rc

# --- Agent invocation function ---
# $1 = agent name, $2 = prompt, $3 = cache file, $4... = model args array
# (e.g. "${CODE_REVIEWER_MODEL_ARGS[@]}" or "${ADVERSARIAL_MODEL_ARGS[@]}",
# possibly empty). Per-call model args replace the old shared global
# MODEL_ARGS so each reviewer can be pinned to its own model (issue #235).
invoke_agent() {
  local agent_name="$1"
  local prompt="$2"
  local cache_file="$3"
  shift 3
  local -a model_args=("$@")

  # An empty cache_file means "always run live, never cache" -- used by
  # callers that need a guaranteed-fresh result (e.g. adversarial-reviewer
  # during a retry-after-FAIL, where a cached PASS from an earlier attempt
  # would feed stale evidence to the arbiter; see claude-config#246).
  # Check cache first
  if [[ -n "${cache_file}" && -f "${cache_file}" ]]; then
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
  agent_output=$(echo "${prompt}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "${agent_name}" -p "${model_args[@]}" --tools "" --no-session-persistence 2>&1) || exit_code=$?

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

  # Cache verdict if PASS (unless caching was disabled via an empty cache_file)
  local _cache_verdict
  _cache_verdict=$(parse_verdict "${agent_output}")
  if [[ -n "${cache_file}" && "${_cache_verdict}" == "PASS" ]]; then
    echo "PASS" >"${cache_file}"
    date -u +%Y-%m-%dT%H:%M:%SZ >>"${cache_file}"
  fi
}

# Records a code-reviewer/adversarial-reviewer disagreement and how the
# arbiter resolved it. claude-config#332 reworked this: it used to file a
# GitHub issue on EVERY disagreement, which had three defects.
#
#   1. Wrong destination. The destination repo is hardcoded to
#      smartwatermelon/claude-config, but four of the six issues ever filed
#      were about beacon-biosignals/infra — a different org entirely.
#   2. Leaked reviewed source. The body pasted all three reviewers' verbatim
#      output, which quotes code from the repo under review. Another org's
#      Terraform (module wiring, cluster names, bucket refs) ended up in a
#      personal repo purely as a side effect.
#   3. Fired on the healthy case. The arbiter ruled PASS in 5 of 6. A strict
#      reviewer disagreeing with a skeptical one is the system working, not
#      a defect worth a tracked issue.
#
# New behavior:
#   * The LOCAL LOG is the default record. Every disagreement appends a full
#     verbatim record (all three reviewers) to ${DISAGREEMENT_LOG}, a sibling
#     of REVIEW_LOG inside this repo's .git/. Verbatim is fine there: it never
#     leaves the machine and it stays with the repo it describes.
#   * A GitHub issue is filed ONLY when the arbiter verdict is FAIL. That is
#     the case where the disagreement says something about the TOOLING (a
#     reviewer produced a finding the arbiter upheld against a PASS), which is
#     why the destination stays hardcoded to this infrastructure's own repo.
#   * When an issue IS filed, it carries only metadata and the arbiter's own
#     reasoning — our tooling's summary, not reviewed source. Reviewer output
#     stays in the local log, which the issue points at by path.
#   * Deduped on (repo, branch) using the local log as the source of truth, so
#     a long-running branch files at most once no matter how many pushes it
#     takes. Issues #323/#324/#325 were one branch re-filing on every push.
#
# Best-effort throughout: this must never block or fail a commit, whatever
# the gh auth state, API result, or writability of the log path.
#
# Reviewer output is MODEL-AUTHORED and untrusted. It is only ever written to
# a file via printf with a literal format string — never eval'd, never
# interpolated into a command, never passed to a search query.
file_reviewer_disagreement_issue() {
  local cr_output="$1" ar_output="$2" arbiter_output="$3" arbiter_verdict="$4"

  local repo_slug="${REPO_OWNER:-unknown}/${REPO_NAME:-unknown}"
  local branch="${_review_branch:-unknown}"
  local commit="${_review_commit:-unknown}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")

  # The local log is the whole record. There is no dedup key any more: it
  # existed only to stop one branch re-filing an issue on every push, and no
  # issue is filed. Existing `filed-issue-for:` lines in old logs are inert.
  #
  # Appended on EVERY disagreement, whatever the arbiter verdict — a PASS
  # disagreement is as diagnostically useful as a FAIL, and neither is
  # published anywhere.
  if [[ -n "${DISAGREEMENT_LOG}" ]]; then
    {
      printf -- '=== REVIEWER DISAGREEMENT %s ===\n' "${ts}"
      printf -- 'repo: %s\n' "${repo_slug}"
      printf -- 'branch: %s\n' "${branch}"
      printf -- 'commit: %s\n' "${commit}"
      printf -- 'arbiter_model: %s\n' "${ARBITER_MODEL:-unknown}"
      printf -- 'arbiter_verdict: %s\n' "${arbiter_verdict}"
      printf -- '--- code-reviewer output ---\n%s\n' "${cr_output}"
      printf -- '--- adversarial-reviewer output ---\n%s\n' "${ar_output}"
      printf -- '--- arbiter reasoning ---\n%s\n' "${arbiter_output}"
      printf -- '=== END DISAGREEMENT ===\n'
    } >>"${DISAGREEMENT_LOG}" 2>/dev/null || true
  fi

  # --- 2. No GitHub issue is filed. ---
  # This used to file into smartwatermelon/claude-config whenever the arbiter
  # returned FAIL, on the premise that an arbiter FAIL is a fact about the
  # TOOLING. Five filings later (claude-config#358/#363/#378/#390/#414) that
  # premise did not hold: not one produced work in this repo.
  #
  # A FAIL means only "the arbiter sided with code-reviewer". In practice that
  # resolved to one of two things, neither a tooling defect:
  #   * The arbiter was right (#390, #414) — the system working as designed.
  #     The finding then belongs to the repo under review, which is usually
  #     not this one: four of the five were about other repos.
  #   * The arbiter was wrong (#358, which hallucinated a variable as
  #     undefined that was defined in the same file). Worth knowing, but the
  #     filed issue reads as a code ticket, so the actual signal is invisible
  #     until a human checks the upstream source.
  #
  # This is the second narrowing of this gate. claude-config#332 removed
  # filing-on-every-disagreement because it "fired on the healthy case"; that
  # change kept the same verdict-keyed shape and kept filing the other half of
  # the healthy case. See claude-config#418 for the evidence.
  #
  # The local log written above remains the record. It is strictly richer than
  # the issue ever was — full verbatim output from all three reviewers, on
  # every disagreement rather than only FAIL — and it stays with the repo it
  # describes, which is also why it carries no cross-org source-leak risk.
  return 0
}

# --- Helper Functions for Progressive Review ---

# Read the developer's commit message for the current invocation, so it can be
# injected into review prompts as "DEVELOPER INTENT". Without this, the
# chunked reviewer judges each file in isolation and can flag false positives
# when the rationale spans files (e.g. a project rename where storage-key
# changes look unsafe unless you also see the bundle-ID change that makes the
# renamed app a fresh install). Echoes nothing when no message is available
# so callers can omit the header entirely instead of emitting an empty one.
#
# Sources by priority:
#   --message-file=PATH     -> read from PATH (highest priority, regardless of mode)
#   commit                  -> $GIT_DIR/COMMIT_EDITMSG (template '#' lines stripped)
#                              NOTE: during pre-commit hook execution this
#                              ALWAYS contains the PREVIOUS commit's message
#                              (per `man githooks`: pre-commit "is invoked
#                              before obtaining the proposed commit log
#                              message"). Use --message-file from the
#                              commit-msg hook to inject the real one.
#   pre-push / default      -> git log -1 --format=%B HEAD
#   codebase                -> empty (no specific commit context)
#
# NOTE: the case statement below still has a `full-diff` label folded into
# the `*` (default) branch, but in practice full-diff mode never reaches
# this function — every path through the full-diff block (~line 828) exits
# before the COMMIT_MSG=$(_read_commit_message) call site (~line 1097). The
# `*` branch currently serves pre-push and any future post-commit mode that
# doesn't early-exit.
_read_commit_message() {
  local msg=""

  # Highest priority: explicit --message-file flag. Used by the commit-msg
  # hook to inject the in-progress message (the only context where it is
  # actually written to disk). Applies regardless of REVIEW_MODE so future
  # callers can override the default source for full-diff / pre-push too.
  #
  # When the flag is set, it is authoritative: if the file is missing or
  # unreadable, return empty (do NOT fall through to the per-mode source).
  # Callers who want the fallback should simply omit --message-file.
  # Rationale: silently substituting a different source on a missing
  # --message-file would re-introduce the very stale-message bug this flag
  # exists to fix (commit-msg hook hands us $1; if $1 is moved/deleted by
  # the time we read it, COMMIT_EDITMSG would be PRE-rewrite and stale).
  if [[ -n "${MESSAGE_FILE:-}" ]]; then
    if [[ -r "${MESSAGE_FILE}" ]]; then
      # || true guards set -e/pipefail: grep exits 1 on an empty/template-only
      # (all-comment) message file, which pipefail would otherwise propagate
      # into this assignment and abort the script. Issue #148.
      msg=$(grep -v '^#' "${MESSAGE_FILE}" 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}') || true
      if [[ -n "${msg//[[:space:]]/}" ]]; then
        printf '%s\n' "${msg}"
      fi
    fi
    return 0
  fi

  case "${REVIEW_MODE}" in
    codebase)
      return 0
      ;;
    commit)
      local git_dir editmsg
      git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
      [[ -n "${git_dir}" ]] || return 0
      editmsg="${git_dir}/COMMIT_EDITMSG"
      [[ -f "${editmsg}" ]] || return 0
      # Strip git-template comment lines (leading '#') and leading/trailing
      # blank lines. Use grep -v to drop comments; awk trims surrounding blanks.
      # || true guards set -e/pipefail: grep exits 1 when COMMIT_EDITMSG is
      # empty or template-only (e.g. --allow-empty-message), which pipefail
      # would otherwise propagate into this assignment and abort. Issue #148.
      msg=$(grep -v '^#' "${editmsg}" 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}') || true
      ;;
    *)
      # pre-push and any future post-commit mode that doesn't early-exit
      # before reaching this function. (full-diff is nominally covered by
      # this branch too, but its early-exit paths never call
      # _read_commit_message in practice — see the note above.)
      msg=$(git log -1 --format=%B HEAD 2>/dev/null \
        | awk 'NF{found=1} found{print}' \
        | awk 'BEGIN{n=0} {lines[n++]=$0} END{end=n-1; while(end>=0 && lines[end]~/^[[:space:]]*$/) end--; for(i=0;i<=end;i++) print lines[i]}')
      ;;
  esac
  # Suppress whitespace-only results so callers can test for "non-empty" cleanly.
  if [[ -n "${msg//[[:space:]]/}" ]]; then
    printf '%s\n' "${msg}"
  fi
}

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

  # Read the commit message ONCE for this run; injected into every per-file
  # prompt so the reviewer sees developer intent across chunks. See
  # _read_commit_message for source-by-mode behavior.
  local commit_msg commit_msg_section
  commit_msg=$(_read_commit_message)
  if [[ -n "${commit_msg}" ]]; then
    commit_msg_section="DEVELOPER INTENT (commit message):
${commit_msg}
---

"
  else
    commit_msg_section=""
  fi

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
    file_prompt="${commit_msg_section}Reviewing file: ${file}

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations
5. Comments: limited to what isn't obvious from the code — flag comments that only restate what the code already says

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
      _fout=$(invoke_agent "${CODE_REVIEWER_AGENT}" "${file_prompt}" "${file_cache}" "${CODE_REVIEWER_MODEL_ARGS[@]}") || true
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

    # Same version-pin-unfamiliarity downgrade as the whole-diff path, applied
    # per-file so chunked review doesn't diverge in behavior from small diffs.
    _rout=$(downgrade_version_unfamiliarity_findings "${_rout}")

    _chunk_verdict=$(parse_verdict "${_rout}")
    if [[ "${_chunk_verdict}" == "FAIL" || "${_chunk_verdict}" == "REVISE" ]]; then
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
  elif [[ ${reviewed_files} -eq 0 && ${file_count} -gt 0 ]]; then
    # Fail-closed: 0 files reviewed out of a nonzero candidate set means the
    # review provided no signal at all (every file was skipped due to agent
    # error, timeout, or oversized chunk). Treating that as a pass makes a
    # totally-broken review indistinguishable from a genuinely clean diff.
    # Issue #200.
    log_error "Chunked review reviewed 0/${file_count} files (all skipped) - cannot verify diff is safe"
    echo "" >&2
    echo "💡 All files were skipped (agent error, timeout, or oversized chunk)." >&2
    echo "   Check the log above for per-file skip reasons, then retry or review manually:" >&2
    echo "   git diff --cached | claude --agent code-reviewer -p --tools \"\"" >&2
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
# Sibling of REVIEW_LOG: the append-only record of code-reviewer /
# adversarial-reviewer disagreements and how the arbiter resolved each one.
# Unlike REVIEW_LOG (truncated each run), this accumulates across runs — it
# doubles as the dedup source of truth for issue filing (claude-config#332).
# Overridable by env var so tests can point it at a temp path.
DISAGREEMENT_LOG="${DISAGREEMENT_LOG:-${GIT_DIR_PATH}/reviewer-disagreements.log}"
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
trap '_ec=$?; rm -rf "${_chunk_results:-}" 2>/dev/null; rm -f "${_cr_out:-}" "${_ar_out:-}" "${DIFF_TMPFILE:-}" "${_codebase_err:-}" 2>/dev/null; [[ -n "${REVIEW_LOG:-}" ]] && printf "exit_code: %d\n" "$_ec" >> "${REVIEW_LOG}" || true' EXIT

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

# Skip review entirely on sync branches.
# `sync/*` branches are created by sync-to-public.sh and contain content
# that has already passed full review in the source (private) repo. Running
# the size-cap check against an aggregated sync diff produces false blocks
# on legitimate, already-reviewed code.
_current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [[ "${REVIEW_MODE}" == "commit" ]] && [[ "${_current_branch}" == sync/* ]]; then
  log_info "Sync branch (${_current_branch}) - skipping review (content already reviewed upstream)"
  printf 'skipped: sync branch (%s)\n' "${_current_branch}" >>"${REVIEW_LOG}" || true
  exit 0
fi
unset _current_branch

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
# MUST stay ABOVE the size dispatch below. A generated file is exempt from
# review regardless of how large it is, so sizing it up first can only ever
# block a commit that would have produced zero findings. A regenerated
# lockfile is one indivisible file, so "split into smaller commits" is not
# available to the human, and `review.skipThreshold` only reroutes it into a
# chunked review that fails on the oversized chunk. Issue #427.
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
# Use a here-string rather than `echo ... | grep -q` — grep -q exits as soon
# as it finds a match, and on a large DIFF that can happen before the pipe's
# writer (echo) finishes, delivering SIGPIPE. Under pipefail the pipeline's
# exit status then becomes echo's 141 instead of grep's real result, so
# `! ...` wrongly evaluates true and the script skips review on a diff that
# DOES have code changes. A here-string has no writer process to race.
# Issues #166, #171 (the removed `2>/dev/null` on echo was a no-op — echo
# cannot fail here since DIFF is always set via `DIFF=$(cat)` above).
if ! grep -qE '^[+-][^+-]' <<<"${DIFF}"; then
  log_info "No code changes detected (permission/metadata only) - skipping review"
  printf 'skipped: permission/metadata only\n' >>"${REVIEW_LOG}" || true
  exit 0
fi

# --- Check for submodule-pointer-only changes ---
# A `Subproject commit <sha>` bump is opaque to every review mode here — this
# script has no access to the submodule's own history, so codebase-mode review
# can only ever restate "contents not inspectable" as a non-blocking issue on
# every bump (see claude-config#192). Operates on DIFF content directly (not
# file names), so — unlike the markdown/lockfile skips above, which are
# commit-mode only — it's safe to apply in every mode, including
# full-diff/codebase where DIFF is piped from main...HEAD rather than the
# staged index.
SUBMODULE_ONLY_LINES=$(echo "${DIFF}" | grep -E '^[+-][^+-]' | grep -vE '^[+-]Subproject commit [0-9a-f]{40}$' || true)
if [[ -z "${SUBMODULE_ONLY_LINES}" ]]; then
  log_info "Submodule-pointer-only changes detected - skipping review (contents not inspectable)"
  printf 'skipped: submodule-pointer-only\n' >>"${REVIEW_LOG}" || true
  exit 0
fi
unset SUBMODULE_ONLY_LINES


# --- Full-diff mode (pre-push cross-file review) ---
if [[ "${REVIEW_MODE}" == "full-diff" ]]; then
  log_info "Full-diff review: analyzing complete feature branch diff"
  log_info "Diff size: ${DIFF_LINES} lines"
  log_info "Model: ${ADVERSARIAL_MODEL}"
  printf 'model: %s\n' "${ADVERSARIAL_MODEL}" >>"${REVIEW_LOG}" || true

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

  FULL_DIFF_OUTPUT=$(invoke_agent "adversarial-reviewer" "${FULL_DIFF_PROMPT}" "${FULL_DIFF_CACHE}" "${ADVERSARIAL_MODEL_ARGS[@]}") || true

  [[ -n "${FULL_DIFF_OUTPUT}" ]] || FULL_DIFF_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

  echo "=== FULL-DIFF REVIEW (adversarial-reviewer) ===" >&2
  echo "${FULL_DIFF_OUTPUT}" >&2
  echo "" >&2

  { printf '=== FULL-DIFF REVIEW ===\n%s\n' "${FULL_DIFF_OUTPUT}"; } >>"${REVIEW_LOG}" || true

  FULL_DIFF_VERDICT=$(parse_verdict "${FULL_DIFF_OUTPUT}")
  if [[ "${FULL_DIFF_VERDICT}" == "PASS" ]]; then
    printf 'full-diff: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Full-diff review passed"
    exit 0
  elif [[ "${FULL_DIFF_VERDICT}" == "FAIL" || "${FULL_DIFF_VERDICT}" == "REVISE" ]]; then
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
  log_info "Model: ${ADVERSARIAL_MODEL}"
  printf 'model: %s\n' "${ADVERSARIAL_MODEL}" >>"${REVIEW_LOG}" || true

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

CLASSIFICATION — two INDEPENDENT questions. Answer both.

1. WHEN did it originate?
   - INTRODUCED by this diff (new bug, new inconsistency), or
   - PRE-EXISTING (was there before this diff).

2. IS IT A DEFECT — would a maintainer change code because of it?
   Something is a defect when it produces a wrong result, a crash, a security
   hole, data loss, a silently skipped check, or a documented behavior the code
   does not deliver. Answering \"no\" here is the common case, and it is a
   complete answer. Say nothing further about it.

Only a defect can be reported at all:
- BLOCK: a DEFECT that is INTRODUCED by this diff. These BLOCK the push.
- NON_BLOCKING_ISSUE: a DEFECT that is PRE-EXISTING. Each one becomes a GitHub
  issue that a human must read, judge, and close by hand.

REPORT NOTHING ELSE. There is no third channel — no FYI, no note for the next
reader, no \"worth verifying\", no \"consider\". If it is not a defect, it does
not go in your output in any form.

DO NOT FILE (this list is where most bad findings come from):
- Anything you would introduce with \"worth noting\", \"worth verifying\",
  \"consider\", \"may want to\", \"for the next person\", or \"no code change
  required\". If that phrasing fits, you have already decided it is not a
  defect. Stop.
- Style, naming, formatting, comment wording, or test-coverage suggestions for
  code that behaves correctly.
- A gap the file's own comments already document as known and accepted.
- Code that works but that you would have written differently.
- A concern you reasoned about and resolved. If your own analysis ends in \"this
  is fine\", \"no defect\", or \"the export covers it\", the finding is finished
  and unfiled. Do not file the reasoning.
- Platform or runtime behavior you cannot check and have no specific reason to
  doubt.

BEFORE EMITTING EACH NON_BLOCKING_ISSUE, CHECK YOURSELF:
Does the DETAILS text end by conceding the thing is fine? If so, delete the
whole block. Measured over 18 filed issues from this reviewer, about half
described no defect, and a third of those said so in their own text while
being filed anyway — every one cost a human a read and a manual close.
Filing nothing is a good outcome and the expected one for a clean diff. An
empty findings list is a successful review, not a lazy one.

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
VERIFIED: <optional; see VERIFIABLE CLAIMS below>
END_ISSUE

VERIFIABLE CLAIMS (mandatory):
YOUR ONLY TOOLS ARE Read, Grep, AND Glob. You cannot run commands. You have no
shell, no Bash, no gh, no test runner. Nothing you write in a VERIFIED: field
was executed, and you must never imply otherwise.

This splits every factual claim into two kinds, and they have DIFFERENT rules.

KIND A — claims about repository contents. What a file contains, whether a
symbol is defined, whether a name is referenced anywhere else, what a config
value is set to. Read/Grep/Glob settle these. For a Kind A claim you must
actually open the file or run the search before asserting it, and record what
you looked at in a VERIFIED: field. Example:
  VERIFIED: Grep \"REVIEW_MAX_LINES=\" hooks/run-review.sh -> line 81, default 1000
Cite the tool and what it returned, not a command you did not run.

KIND B — claims about how a tool, shell construct, or runtime BEHAVES. \"printf
appends another newline here\", \"$( ) keeps the trailing newline\", \"argv[1] is
the script path\", \"if: failure() only covers the previous step\", \"grep -w
splits on /\", \"this flag does not exist\", \"an empty object passes\". You
CANNOT check any of these. Reading the source that calls a tool tells you what
the code does, never what the tool does with it.

FOR EVERY KIND B CLAIM, THE SOFTENED FORM IS MANDATORY, NOT A FALLBACK.
Phrase it as a question and say what would settle it. Write:
  \"does printf re-add a trailing newline here — worth checking whether $( )
   already stripped it?\"
NOT:
  \"printf appends another newline, producing a blank line between blocks.\"
Both sentences point at the same line of code. Only the first is honest about
what you actually know. A Kind B claim stated as fact is wrong even when the
underlying suspicion is right, because you are reporting a guess as a
measurement — and a human then spends a command disproving it.

A Kind B claim is not rescued by confidence, by how standard the behavior
seems, or by how much surrounding code you read. If your finding's core
assertion is about runtime behavior, it goes in question form. No exceptions.

Never assert a checkable fact you did not check. Findings that assert
incorrectness with no VERIFIED: field are filed with an \"unverified\" label
and a warning banner, because past unverified assertions of exactly this
shape turned out to be false and cost a human real time to disprove.
VERIFIED: is optional and should be omitted entirely when the finding makes
no factual claim about external state (style, structure, maintainability)."

  log_info "Running codebase reviewer with tool access..."
  codebase_start=$(date +%s)

  codebase_exit=0
  # Invoke WITHOUT --tools "" so agent gets default tool access (Read, Grep, Glob).
  # --allowedTools restricts to safe read-only tools only.
  # stderr is routed to its own temp file rather than merged via 2>&1: CLI
  # upgrade notices / deprecation warnings on stderr would otherwise land in
  # CODEBASE_OUTPUT and could corrupt the `grep -q "VERDICT:"` parsing below.
  # Matches the pattern used for the parallel code-reviewer/adversarial
  # invocations (_cr_out/_ar_out). Issue #89.
  _codebase_err=$(mktemp)
  CODEBASE_OUTPUT=$(echo "${CODEBASE_PROMPT}" | timeout "${TIMEOUT_SECONDS}" env -u CLAUDECODE "${CLAUDE_CLI}" --agent "adversarial-reviewer" -p "${ADVERSARIAL_MODEL_ARGS[@]}" --allowedTools "Read,Grep,Glob" --no-session-persistence 2>"${_codebase_err}") || codebase_exit=$?
  if [[ -s "${_codebase_err}" ]]; then
    cat "${_codebase_err}" >&2
  fi
  rm -f "${_codebase_err}"
  unset _codebase_err

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
  CODEBASE_VERDICT=$(parse_verdict "${CODEBASE_OUTPUT}")
  if [[ "${CODEBASE_VERDICT}" == "PASS" ]]; then
    echo "PASS" >"${CODEBASE_CACHE}"
    printf 'codebase: PASS\n' >>"${REVIEW_LOG}" || true
    log_success "Codebase review passed"

    # Extract and file non-blocking issues (best-effort, never blocks)
    if echo "${CODEBASE_OUTPUT}" | grep -q "NON_BLOCKING_ISSUE:"; then
      log_info "Filing non-blocking issues found during codebase review..."
      create_nonblocking_issues "${CODEBASE_OUTPUT}" || true
    fi

    exit 0
  elif [[ "${CODEBASE_VERDICT}" == "FAIL" || "${CODEBASE_VERDICT}" == "REVISE" ]]; then
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
ROUND_HISTORY_KEY=$(round_history_key "${CHANGED_FILES}")
ROUND_HISTORY_FILE=""
if [[ -n "${ROUND_HISTORY_KEY}" && "${ROUND_HISTORY_KEY}" != "noround" ]]; then
  ROUND_HISTORY_FILE="${CACHE_DIR}/round-history-${ROUND_HISTORY_KEY}"
else
  log_warn "Could not compute round-history key; this run's review will not carry prior-round feedback"
fi

# adversarial-reviewer's cache is deliberately bypassed during a retry after a
# prior FAIL on this branch/file-set (i.e. ROUND_HISTORY_FILE has content).
# The arbiter (below) treats an adversarial PASS as evidence that
# code-reviewer's current BLOCKING claim doesn't hold up -- but a cache hit
# means adversarial-reviewer never actually looked at *this* code-reviewer
# FAIL; it only proves some earlier attempt at this diff passed adversarial
# review, possibly before code-reviewer's current objection even existed.
# Live-only here forces a fresh, substantive check exactly when arbitration
# is most likely to be invoked. dev-env#35 / claude-config#246: a stale
# cached PASS was silently reused across retries and misled the arbiter,
# which noticed the cache was stale but sided with a fabricated
# code-reviewer claim anyway rather than treating "no fresh evidence" as a
# reason to force a live check.
_prior_round_feedback_present=""
[[ -n "${ROUND_HISTORY_FILE}" ]] && _prior_round_feedback_present=$(read_round_feedback "${ROUND_HISTORY_FILE}")
if [[ -n "${_prior_round_feedback_present}" ]]; then
  log_info "Retry after a prior FAIL on this branch/file-set -- forcing a live adversarial-reviewer check (bypassing cache)"
  ADVERSARIAL_CACHE="" # empty = invoke_agent always runs live, never caches
else
  ADVERSARIAL_CACHE="${CACHE_DIR}/adversarial-${DIFF_HASH}"
fi
unset _prior_round_feedback_present

# Build structured prompt for agents
# Use string concatenation - safe variable expansion without command execution
#
# File-header context: give the reviewer each changed file's stated scope
# (e.g. "macOS-only, not intended for Linux/CI") even when that line isn't
# part of the diff hunk itself. Diff-only prompts can't see this — dev-env#35.
FILE_CONTEXT_SECTION=""
if [[ -n "${CHANGED_FILES}" ]]; then
  while IFS= read -r _cf; do
    [[ -z "${_cf}" ]] && continue
    _cf_header=$(extract_file_header_context "${_cf}")
    [[ -n "${_cf_header}" ]] || continue
    FILE_CONTEXT_SECTION="${FILE_CONTEXT_SECTION}--- ${_cf} ---
${_cf_header}

"
  done <<<"${CHANGED_FILES}"
  if [[ -n "${FILE_CONTEXT_SECTION}" ]]; then
    FILE_CONTEXT_SECTION="FILE HEADER CONTEXT (stated scope/intent from each changed file's leading comments — weigh findings against this before flagging out-of-scope concerns):
${FILE_CONTEXT_SECTION}---

"
  fi
fi
unset _cf _cf_header

# Inject prior-round feedback from a failed review attempt on this branch/file-set.
# Each --no-session-persistence invocation starts from zero, so a FAILed round's
# findings were forgotten by the next retry. Track up to the last 2 rounds and
# inject them so retries build on prior findings instead of re-litigating.
PRIOR_ROUND_SECTION=""
if [[ -n "${ROUND_HISTORY_FILE}" ]]; then
  _prior_feedback=$(read_round_feedback "${ROUND_HISTORY_FILE}")
  if [[ -n "${_prior_feedback}" ]]; then
    if grep -qE "^VERDICT: (PASS|FAIL|REVISE)" <<<"${_prior_feedback}"; then
      PRIOR_ROUND_SECTION="PRIOR ROUND FEEDBACK (from up to 2 previous FAILed review attempts on this branch/file-set — do NOT re-flag an issue below unless it is still genuinely present in the current diff; do not propose a different remedy for something already addressed):
${_prior_feedback}
---

"
    else
      log_warn "Round-history file at ${ROUND_HISTORY_FILE} has no VERDICT line; discarding as invalid"
      clear_round_feedback "${ROUND_HISTORY_FILE}"
    fi
  fi
fi
unset _prior_feedback

# Inject the developer's commit message (when available) so the reviewer sees
# intent before code. Same pattern as the chunked path; section is omitted
# entirely when no message is available.
COMMIT_MSG=$(_read_commit_message)
if [[ -n "${COMMIT_MSG}" ]]; then
  COMMIT_MSG_SECTION="DEVELOPER INTENT (commit message):
${COMMIT_MSG}
---

"
else
  COMMIT_MSG_SECTION=""
fi

AGENT_PROMPT="${PRIOR_ROUND_SECTION}${FILE_CONTEXT_SECTION}${COMMIT_MSG_SECTION}You are performing a pre-commit code review. Analyze the diff below and identify issues BEFORE code is committed.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

Focus on:
1. Correctness: Logic errors, null handling, race conditions
2. Security: Hardcoded secrets, injection vulnerabilities, auth issues
3. Error Handling: Silent failures, missing error cases
4. Completeness: Edge cases, incomplete implementations
5. Comments: limited to what isn't obvious from the code — flag comments that only restate what the code already says

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
if [[ -n "${REVIEW_MODEL}" ]]; then
  log_info "Model: ${REVIEW_MODEL}"
  printf 'model: %s\n' "${REVIEW_MODEL}" >>"${REVIEW_LOG}" || true
fi

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
  (invoke_agent "${CODE_REVIEWER_AGENT}" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}" "${CODE_REVIEWER_MODEL_ARGS[@]}" >"${_cr_out}") &
  _cr_pid=$!
  (invoke_agent "adversarial-reviewer" "${AGENT_PROMPT}" "${ADVERSARIAL_CACHE}" "${ADVERSARIAL_MODEL_ARGS[@]}" >"${_ar_out}") &
  _ar_pid=$!
  wait "${_cr_pid}" || true
  wait "${_ar_pid}" || true
  CODE_REVIEWER_OUTPUT=$(cat "${_cr_out}")
  ADVERSARIAL_OUTPUT=$(cat "${_ar_out}")
  rm -f "${_cr_out}" "${_ar_out}"
  unset _cr_out _ar_out _cr_pid _ar_pid
else
  # Serial path (no adversarial): only code-reviewer runs.
  CODE_REVIEWER_OUTPUT=$(invoke_agent "${CODE_REVIEWER_AGENT}" "${AGENT_PROMPT}" "${CODE_REVIEWER_CACHE}" "${CODE_REVIEWER_MODEL_ARGS[@]}") || true
fi

# Guard: invoke_agent may exit 0 but produce no output (silent agent failure).
# Normalise to a transient-error verdict so the non-blocking check below handles it.
[[ -n "${CODE_REVIEWER_OUTPUT}" ]] || CODE_REVIEWER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  [[ -n "${ADVERSARIAL_OUTPUT}" ]] || ADVERSARIAL_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"
fi

# Version-pin-unfamiliarity downgrade: rewrite qualifying BLOCKING findings
# to WARNING before verdict parsing, so a downgraded issue no longer flips
# the verdict to FAIL. Applied to both reviewers' raw output.
CODE_REVIEWER_OUTPUT=$(downgrade_version_unfamiliarity_findings "${CODE_REVIEWER_OUTPUT}")
if [[ "${ADVERSARIAL_AVAILABLE}" == true ]]; then
  ADVERSARIAL_OUTPUT=$(downgrade_version_unfamiliarity_findings "${ADVERSARIAL_OUTPUT}")
fi

# Parse verdict from code-reviewer output
CODE_REVIEWER_VERDICT=$(parse_verdict "${CODE_REVIEWER_OUTPUT}")
if [[ "${CODE_REVIEWER_VERDICT}" == "PASS" ]]; then
  : # already PASS
elif [[ "${CODE_REVIEWER_VERDICT}" == "FAIL" || "${CODE_REVIEWER_VERDICT}" == "REVISE" ]]; then
  CODE_REVIEWER_VERDICT="FAIL" # normalize REVISE -> FAIL for downstream contract
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
  ADVERSARIAL_VERDICT=$(parse_verdict "${ADVERSARIAL_OUTPUT}")
  if [[ "${ADVERSARIAL_VERDICT}" == "PASS" ]]; then
    : # already PASS
  elif [[ "${ADVERSARIAL_VERDICT}" == "FAIL" || "${ADVERSARIAL_VERDICT}" == "REVISE" ]]; then
    ADVERSARIAL_VERDICT="FAIL" # normalize REVISE -> FAIL for downstream contract
  else
    log_error "Could not parse adversarial-reviewer verdict"
    log_error "BLOCKING: Cannot verify adversarial review result"
    log_error ""
    log_error "Output was:"
    echo "${ADVERSARIAL_OUTPUT}" | head -20 >&2
    exit 1
  fi
fi

if [[ -n "${ROUND_HISTORY_FILE}" ]]; then
  if [[ "${CODE_REVIEWER_VERDICT}" == "PASS" ]]; then
    clear_round_feedback "${ROUND_HISTORY_FILE}"
  else
    write_round_feedback "${ROUND_HISTORY_FILE}" "${CODE_REVIEWER_OUTPUT}"
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
    # Reconciliation: if adversarial-reviewer (already a bigger model,
    # already reasoning about failure modes) independently reached PASS,
    # don't take code-reviewer's BLOCKING FAIL as final — ask a third
    # agent to arbitrate rather than silently trusting either side.
    # dev-env#35: non-convergent Haiku findings that adversarial-reviewer
    # explicitly called "solid design choices" on the same diff.
    if [[ "${ADVERSARIAL_AVAILABLE}" == true && "${ADVERSARIAL_VERDICT}" == "PASS" ]]; then
      log_warn "code-reviewer BLOCKING FAIL disagrees with adversarial-reviewer PASS — arbitrating"

      ARBITER_PROMPT="Two reviewers disagree on whether this diff is safe to commit. Read both verdicts and the diff, then decide which reviewer is correct.

IMPORTANT: You are being invoked as a focused analysis tool with --no-session-persistence.
Do NOT output Protocol 0 environment check or any preamble.
Begin your response directly with the verdict in the specified format below.

=== CODE-REVIEWER VERDICT (found a BLOCKING issue) ===
${CODE_REVIEWER_OUTPUT}

=== ADVERSARIAL-REVIEWER VERDICT (found no blocking issue) ===
${ADVERSARIAL_OUTPUT}

=== DIFF UNDER REVIEW ===
\`\`\`diff
${DIFF}
\`\`\`

Decide: is code-reviewer's BLOCKING finding a genuine, currently-present issue in this diff, or is adversarial-reviewer correct that it doesn't apply (e.g. out of stated scope, already mitigated, a false positive)?

CRITICAL: Respond with this exact format:

VERDICT: [PASS or FAIL]

[Explain which reviewer is correct and why, in 2-4 sentences.]

[If VERDICT: FAIL, restate the still-blocking issue:]
ISSUE: [one-line description]
SEVERITY: BLOCKING
LOCATION: [file:line]
DETAILS: [explanation and fix]"

      ARBITER_CACHE="${CACHE_DIR}/arbiter-${DIFF_HASH}"
      ARBITER_OUTPUT=$(invoke_agent "adversarial-reviewer" "${ARBITER_PROMPT}" "${ARBITER_CACHE}" "${ARBITER_MODEL_ARGS[@]}") || true
      [[ -n "${ARBITER_OUTPUT}" ]] || ARBITER_OUTPUT="VERDICT: FAIL (agent error: invoke_agent produced no output)"

      echo "=== ARBITER (reconciling code-reviewer vs adversarial-reviewer) ===" >&2
      echo "${ARBITER_OUTPUT}" >&2
      echo "" >&2
      { printf '=== ARBITER ===\n%s\n' "${ARBITER_OUTPUT}"; } >>"${REVIEW_LOG}" || true

      ARBITER_VERDICT=$(parse_verdict "${ARBITER_OUTPUT}")
      [[ -n "${ARBITER_VERDICT}" ]] || ARBITER_VERDICT="FAIL"
      printf 'arbiter: %s\n' "${ARBITER_VERDICT}" >>"${REVIEW_LOG}" || true

      file_reviewer_disagreement_issue "${CODE_REVIEWER_OUTPUT}" "${ADVERSARIAL_OUTPUT}" "${ARBITER_OUTPUT}" "${ARBITER_VERDICT}"

      if [[ "${ARBITER_VERDICT}" == "PASS" ]]; then
        log_success "Arbiter sided with adversarial-reviewer — commit allowed"
        # write_round_feedback already persisted code-reviewer's FAIL output
        # before this block ran (it only sees CODE_REVIEWER_VERDICT, not the
        # arbiter's later ruling). The arbiter just determined that FAIL was
        # a false positive, so clear it -- otherwise it survives into the
        # next commit's PRIOR ROUND FEEDBACK as an already-resolved finding.
        [[ -n "${ROUND_HISTORY_FILE}" ]] && clear_round_feedback "${ROUND_HISTORY_FILE}"
      else
        log_error "Arbiter sided with code-reviewer - commit rejected"
        exit 1
      fi
    else
      log_error "code-reviewer found blocking issues - commit rejected"
      exit 1
    fi
  else
    log_warn "code-reviewer found warnings (non-blocking)"
    # Continue to adversarial if security-critical
  fi
fi

if [[ "${ADVERSARIAL_VERDICT}" == "FAIL" ]]; then
  # Transient infrastructure failures (timeout, CLI crash) produce "VERDICT: FAIL (timeout)"
  # or "VERDICT: FAIL (agent error: N)" with no SEVERITY: BLOCKING — treat as non-blocking,
  # consistent with how code-reviewer handles the same case. Also matches a
  # "Revise (...)" form in case a future synthetic transient error is ever
  # phrased that way instead of "FAIL (...)" (#172).
  if echo "${ADVERSARIAL_OUTPUT}" | grep -qE "VERDICT: (FAIL|Revise) \((timeout|agent error)"; then
    log_warn "adversarial-reviewer timed out or errored — non-blocking (infrastructure failure)"
  elif echo "${ADVERSARIAL_OUTPUT}" | grep -q "SEVERITY: BLOCKING"; then
    # Symmetric with the code-reviewer gate above: only a BLOCKING severity
    # rejects the commit. A warnings-only FAIL is logged but non-blocking.
    # Issue #199.
    log_error "adversarial-reviewer found issues - commit rejected"
    log_error "Note: code-reviewer passed but adversarial-reviewer caught additional concerns"
    exit 1
  else
    log_warn "adversarial-reviewer found warnings (non-blocking)"
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
