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

# Intended to memoize the authenticated gh login for the lifetime of this
# shell process — but only actually caches when called without a subshell
# (i.e. bare `_cached_gh_login`, then read `_GH_LOGIN_CACHE` directly).
# Calling it via command substitution, as `is_self_authored` does
# (`my_login=$(_cached_gh_login)`), runs the assignment in a subshell that
# never writes back to the parent's `_GH_LOGIN_CACHE`, so `gh api user` is
# re-run on every call. Currently harmless: `is_self_authored` only calls
# this once per `create_nonblocking_issues` invocation. If a second call
# site is ever added, either restructure to avoid the subshell or accept the
# repeated `gh api user` calls.
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

# Extract TITLE/SOURCE/LOCATION/DETAILS/VERIFIED fields from a single issue
# block. Writes results into the nameref args (caller-declared local vars).
# The fifth nameref (VERIFIED, #328 gate 3) is OPTIONAL: callers that predate
# it pass only four names, and the field is simply not extracted for them.
#
# VERIFIED is a multi-line field like DETAILS, but unlike DETAILS it is not
# open-ended — it terminates at the next known field header so a VERIFIED:
# block placed before DETAILS: doesn't swallow it. DETAILS keeps its original
# swallow-everything behavior, but now stops at a VERIFIED: header for the
# same reason.
#
# Both multi-line fields also stop at a bare END_ISSUE line (#333). In the
# normal flow that line is already gone — parse_nonblocking_issues() consumes
# END_ISSUE as the block terminator and never emits it — so this is defensive
# hardening, not a live bug fix: it removes a silent dependency on that
# call-site behavior, so a caller that hands _parse_issue_fields a raw block
# with its terminator still attached can't get END_ISSUE swallowed into the
# tail of DETAILS or VERIFIED.
_parse_issue_fields() {
  local block="$1"
  local -n _pif_title="$2"
  local -n _pif_source="$3"
  local -n _pif_location="$4"
  local -n _pif_details="$5"

  _pif_title=$(echo "${block}" | { grep "^TITLE:" || true; } | { head -1 || true; } | sed 's/^TITLE: //')
  _pif_source=$(echo "${block}" | { grep "^SOURCE:" || true; } | { head -1 || true; } | sed 's/^SOURCE: //')
  _pif_location=$(echo "${block}" | { grep "^LOCATION:" || true; } | { head -1 || true; } | sed 's/^LOCATION: //')
  # DETAILS may span multiple lines -- grab everything after the DETAILS: line,
  # stopping at a VERIFIED: header or an END_ISSUE terminator if one follows.
  _pif_details=$(echo "${block}" | { awk '/^VERIFIED:/{found=0} /^END_ISSUE$/{found=0} /^DETAILS:/{found=1; sub(/^DETAILS: /,""); print; next} found{print}' || true; } | { sed '/^[[:space:]]*$/d' || true; })

  # VERIFIED is optional and so is this nameref.
  if [[ -n "${6:-}" ]]; then
    local -n _pif_verified="$6"
    _pif_verified=$(echo "${block}" | { awk '/^(TITLE|SOURCE|LOCATION|DETAILS):/{found=0} /^END_ISSUE$/{found=0} /^VERIFIED:/{found=1; sub(/^VERIFIED:[[:space:]]*/,""); print; next} found{print}' || true; } | { sed '/^[[:space:]]*$/d' || true; })
  fi
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
    command gh label create "unverified" --color "#fbca04" --description "Finding asserts a fact that was never checked" --repo "${REPO_OWNER}/${REPO_NAME}" --force >/dev/null 2>&1 || true
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

# Does REPO_OWNER/REPO_NAME have GitHub Issues enabled? Cached for the
# lifetime of this shell process — a single review run can produce many
# NON_BLOCKING_ISSUE findings, and re-probing the API for every one would be
# wasteful. When Issues are disabled, `gh issue create` fails loudly on
# every single finding (30 stderr warnings observed in one push in the
# field); checking this once lets callers skip straight to the
# fallback-file path instead of attempting (and failing) the API call.
# See #180.
#
# Fails OPEN: only an explicit "false" from a successful API lookup is
# treated as disabled. Any other outcome (network error, auth failure,
# empty response, rate limit) is treated as enabled, so a transient lookup
# failure never silently suppresses issue filing — it just falls through
# to the existing `gh issue create` failure/fallback handling, same as
# before this change.
_HAS_ISSUES_CACHE=""
_repo_has_issues_enabled() {
  if [[ -z "${_HAS_ISSUES_CACHE:-}" ]]; then
    local result
    result=$(command gh api "repos/${REPO_OWNER}/${REPO_NAME}" --jq '.has_issues' 2>/dev/null) || true
    if [[ "${result}" == "false" ]]; then
      _HAS_ISSUES_CACHE="false"
    else
      _HAS_ISSUES_CACHE="true"
    fi
  fi
  [[ "${_HAS_ISSUES_CACHE}" == "true" ]]
}

# ---------------------------------------------------------------
# Deduplication against existing OPEN issues (#328)
# ---------------------------------------------------------------
#
# The reviewer files a fresh issue for every finding it emits, with no
# memory of what it already filed. In the field that produced 24 auto-filed
# issues in one day, the largest single cluster being 8+ issues all
# re-litigating one settled pinning-policy decision, plus repeat filings of
# the same finding across successive PRs touching the same line.
#
# WHAT COUNTS AS "SIMILAR ENOUGH"
#
# Two signals, both required:
#
#   1. Same FILE PATH. The LOCATION field ("path/to/file.yml:23") is the
#      most stable identity a finding has. Observed duplicates in
#      smartwatermelon/dotfiles (#193 ":23", #195 ":31", #197 ":23") are the
#      same objection at drifting line numbers, so the line suffix is
#      stripped and only the path is compared. Findings with no usable path
#      (LOCATION "general", or empty) are never deduped — there is no
#      identity to match on, so they always file.
#
#   2. Overlapping TITLE keywords. Path alone is too blunt: two genuinely
#      distinct findings in one large file would collide. Titles are model
#      authored and get rephrased freely between runs (#193 "Reusable
#      workflow reference moved from immutable SHA pin to mutable tag" vs
#      #195 "claude.yml switched from immutable commit-SHA pin to mutable
#      named tag"), so exact-title match catches none of the real
#      duplicates. Instead both titles are reduced to lowercased
#      alphanumeric tokens of 4+ characters, stopwords dropped, and a match
#      requires at least _DEDUP_MIN_TOKEN_OVERLAP tokens in common. The pair
#      above shares exactly two significant tokens ("immutable", "mutable"),
#      which is why the threshold is 2 and not higher; an unrelated finding
#      in the same file shares none.
#
# Deliberately NOT done here: commenting on the matched issue. That trades
# one noise problem for another, and is out of scope for this change.
#
# FAILS OPEN. Only a successful listing that yields a confident match
# suppresses a filing. A search error, timeout, empty/garbled response, or
# missing jq output all fall through to filing the issue exactly as before —
# same reasoning as _repo_has_issues_enabled(): a transient lookup failure
# must never silently swallow a finding.

# Minimum number of shared significant title tokens for a match.
_DEDUP_MIN_TOKEN_OVERLAP=2

# Common English words that carry no identifying signal about a finding.
_DEDUP_STOPWORDS='this|that|with|from|when|then|than|were|will|would|should|could|have|been|does|into|only|also|same|such|they|them|there|where|which|while|about|after|before|being|other|using|used|make|made|more|most|some'

# Reduce a title to a sorted, unique list of significant lowercase tokens
# (alphanumeric, 4+ chars, stopwords removed), one per line.
_dedup_title_tokens() {
  printf '%s' "$1" |
    { tr '[:upper:]' '[:lower:]' || true; } |
    { tr -cs '[:alnum:]' '\n' || true; } |
    { grep -E '^[[:alnum:]]{4,}$' || true; } |
    { grep -vxE "${_DEDUP_STOPWORDS}" || true; } |
    { sort -u || true; }
}

# Extract the bare file path from a LOCATION field, dropping any line-number
# or line-range suffix. Prints nothing when LOCATION carries no real path.
_dedup_location_path() {
  local location="$1"
  # Strip a trailing ":<digits>" or ":<digits>-<digits>" suffix.
  local path_only="${location}"
  path_only="$(printf '%s' "${path_only}" | sed -E 's/:[0-9]+(-[0-9]+)?[[:space:]]*$//')"
  path_only="${path_only#"${path_only%%[![:space:]]*}"}"
  path_only="${path_only%"${path_only##*[![:space:]]}"}"

  # A usable path needs a path separator or an extension; bare words like
  # "general" or "multiple files" carry no identity worth matching on.
  case "${path_only}" in
    "" | general | "multiple files" | various | n/a | N/A) return 0 ;;
    *) ;;
  esac
  if [[ "${path_only}" == */* || "${path_only}" == *.* ]]; then
    printf '%s' "${path_only}"
  fi
}

# Cache of open issues for REPO_OWNER/REPO_NAME, as TSV: number, url, title,
# location-path. Populated at most once per process (a single review can emit
# many findings; one listing serves them all — same rationale and house style
# as _HAS_ISSUES_CACHE).
#
# _OPEN_ISSUES_STATE is "" (not yet fetched), "ok" (usable listing, possibly
# empty), or "error" (lookup failed — dedup disabled, everything files).
#
# _OPEN_ISSUES_LIMIT is gh's documented maximum for `issue list --limit`.
# Asking for the maximum is free — gh paginates internally and returns only
# what exists — so there is no cost to raising it, and a repo that really has
# grown past the old 200 no longer loses its tail silently.
_OPEN_ISSUES_LIMIT=1000
_OPEN_ISSUES_CACHE=""
_OPEN_ISSUES_STATE=""
_load_open_issues() {
  [[ -n "${_OPEN_ISSUES_STATE}" ]] && return 0

  local raw jq_prog
  # Literal jq program (single-quoted on purpose: $-free, and the escapes are
  # jq's, not the shell's). Extracts the "**Location:** `path`" line that
  # build_issue_body() writes into every auto-filed issue body.
  # The backtick delimiters are written as \u0060 escapes rather than literal
  # backticks so the single-quoted program contains no character the shell
  # could read as a command substitution.
  jq_prog='.[] | [(.number|tostring), .url, (.title|gsub("[\t\n\r]";" ")), ((.body // "" | capture("\\*\\*Location:\\*\\* \u0060(?<l>[^\u0060]*)\u0060").l) // "")] | @tsv'
  # NOTE: no --search. The reviewer rephrases titles freely, so a keyword
  # search would miss the very duplicates this targets, so the whole open list
  # is fetched and filtered locally instead. Untrusted model-authored text is
  # therefore never interpolated into a query at all. On the repos this runs
  # against the list is normally small (tens of issues), but that is an
  # observation, not a guarantee — hence the explicit _OPEN_ISSUES_LIMIT and
  # the truncation check below.
  if ! raw=$(command gh issue list \
    --repo "${REPO_OWNER}/${REPO_NAME}" \
    --state open \
    --limit "${_OPEN_ISSUES_LIMIT}" \
    --json number,url,title,body \
    --jq "${jq_prog}" 2>/dev/null); then
    _OPEN_ISSUES_STATE="error"
    return 0
  fi

  # Probable-truncation check (#330). gh gives no "there was more" signal, so
  # the only tell is a row count that lands exactly on the requested limit.
  # That is suggestive, not proof (a repo with precisely _OPEN_ISSUES_LIMIT
  # open issues is a false positive), which is why this warns rather than
  # setting "error": the listing we did get is still usable for dedup, it just
  # may be incomplete, and the operator should know that a duplicate slipping
  # through has a known explanation.
  local row_count
  row_count=$(printf '%s' "${raw}" | { grep -c . || true; })
  if [[ "${row_count}" -ge "${_OPEN_ISSUES_LIMIT}" ]]; then
    log_warn "Open-issue listing for ${REPO_OWNER}/${REPO_NAME} hit the ${_OPEN_ISSUES_LIMIT}-issue limit; dedup may be incomplete and duplicates may be filed."
  fi

  _OPEN_ISSUES_CACHE="${raw}"
  _OPEN_ISSUES_STATE="ok"
}

# Find an existing OPEN issue that duplicates this finding.
# Args: title location
# Prints "<number>\t<url>" on a confident match; prints nothing otherwise.
_find_duplicate_open_issue() {
  local title="$1"
  local location="$2"

  local new_path
  new_path=$(_dedup_location_path "${location}")
  # No usable path identity -> never dedup, always file.
  [[ -n "${new_path}" ]] || return 0

  # NOTE: deliberately does NOT call _load_open_issues here. This function is
  # invoked via command substitution, so any cache assignment it made would
  # happen in a subshell and be discarded — the same trap documented above for
  # _cached_gh_login, which is why that one re-runs `gh api user` every call.
  # _process_issue_block primes the cache in the parent shell before calling
  # this, so the listing really is fetched once per run.
  # Fail open: a failed lookup disables dedup entirely for this run.
  [[ "${_OPEN_ISSUES_STATE}" == "ok" ]] || return 0
  [[ -n "${_OPEN_ISSUES_CACHE}" ]] || return 0

  local new_tokens
  new_tokens=$(_dedup_title_tokens "${title}")
  [[ -n "${new_tokens}" ]] || return 0

  local num url existing_title existing_loc existing_path overlap
  while IFS=$'\t' read -r num url existing_title existing_loc; do
    [[ -n "${num}" ]] || continue
    existing_path=$(_dedup_location_path "${existing_loc}")
    [[ -n "${existing_path}" ]] || continue
    [[ "${existing_path}" == "${new_path}" ]] || continue

    local existing_tokens shared
    existing_tokens=$(_dedup_title_tokens "${existing_title}")
    [[ -n "${existing_tokens}" ]] || continue
    shared=$(comm -12 <(printf '%s\n' "${new_tokens}") <(printf '%s\n' "${existing_tokens}"))
    overlap=$(printf '%s' "${shared}" | { grep -c . || true; })
    if [[ "${overlap}" -ge "${_DEDUP_MIN_TOKEN_OVERLAP}" ]]; then
      printf '%s\t%s' "${num}" "${url}"
      return 0
    fi
  done <<<"${_OPEN_ISSUES_CACHE}"
}

# ---------------------------------------------------------------
# Verifiable-claims gate (#328, gate 3)
# ---------------------------------------------------------------
#
# On 2026-08-17 the reviewer filed several findings that asserted something
# about external state and were simply WRONG, each costing a human a manual
# disproof:
#
#   github-workflows#131 — asserted a specific actions/checkout SHA
#     "belongs to the v4.x release line, not v7.0.1 (which does not exist
#     for this action)". One `gh api` call resolves that. It was never run.
#     The annotation under attack was correct.
#   github-workflows#148 — asserted that quoting a variable in
#     CLAUDE_ARGS="--model \"$MODEL\"" makes the string "now contain
#     literal \" around the model name". One `echo` disproves that; bash
#     resolves the escaping at assignment. The finding even said it "has
#     not been tested in a live run" — and was filed anyway.
#
# The shared defect is NOT "the finding was wrong". It is: an assertion
# about verifiable external state, made without checking it. That is what
# this gate targets.
#
# WHAT IT DOES: annotate and label. It does NOT suppress. A finding whose
# claim carries no supporting command still files — it just files carrying a
# visible "unverified claim" caveat and an `unverified` label, so a human
# reading the issue knows the assertion has not been checked before spending
# time on it. Suppression is gate 1's job (dedup, above); a lost finding is
# strictly worse than a labelled noisy one.
#
# FAILS OPEN in the strongest sense: there is no path through this code that
# can prevent a filing. The worst case is that the caveat or the label is
# missing.

# Literal, deliberately small set of assertion markers. Matched
# case-insensitively as fixed strings against TITLE + DETAILS. Kept dumb on
# purpose: every entry here is a phrase that states external state is
# factually wrong, as opposed to the hedged/suggestive phrasing ("consider",
# "may want to", "it is unclear whether") that carries no factual claim and
# so needs no verification. Do not grow this into a cleverness contest.
#
# Two groups, both narrow:
#
#   1. Direct assertions — "X is incorrect".
#   2. Self-admitted-unverified assertions (#337) — the finding makes a
#      factual claim and states in the same breath that it never checked it.
#      github-workflows#148 is the motivating case: it asserted a bash
#      escaping behaviour, then wrote "has not been tested in a live run",
#      and was filed anyway. It turned out to be wrong. This is NOT the
#      harmless hedging described above: a claim the author flags as
#      unchecked is precisely what this gate exists to label.
#
# Calibrated against a 137-finding corpus of every reviewer-filed issue
# across the fleet (see PR for the measurement). The phrases proposed in
# claude-config#334 were measured and deliberately REJECTED:
#   - "is not present" / "cannot be found" / "contains no" -> 0 real matches
#   - "is not" (9 matches) and "has no" (9) are far too broad. In the corpus
#     they overwhelmingly catch the reviewer being CAREFUL — "this is not a
#     correctness issue", "is not currently vulnerable", "this is not a
#     confirmed regression". Flagging those as unverified assertions would
#     invert the gate's meaning and punish exactly the phrasing we want.
# The additions below flag exactly one more finding in 137 (#148) and zero
# false positives. Re-run the measurement before adding anything.
_VERIFY_ASSERTION_MARKERS=(
  # Group 1: direct assertions of incorrectness.
  "is incorrect"
  "are incorrect"
  "is wrong"
  "is factually"
  "does not exist"
  "doesn't exist"
  "will fail"
  "is broken"
  "never runs"
  # Group 2: the finding admits, in its own text, that it never checked.
  "has not been tested"
  "has not been verified"
  "has not been confirmed"
  "was not verified"
  "not been validated"
  # Group 3: claims about how a tool, runtime, or API actually BEHAVES
  # (projectinsomnia #124/#128/#131/#132/#133/#137). Six findings in one
  # session asserted mechanism -- what process.argv holds, whether `if:
  # failure()` covers a prior step, how `grep -w` treats `/`, whether an
  # empty vulnerabilities object passes -- and all six were wrong. None used
  # Group 1 phrasing, so none were labelled; each cost a human a command to
  # disprove.
  #
  # These are worth flagging precisely because they are the CHEAPEST claims
  # to check: every one fell to a single one-liner. A reviewer asserting
  # mechanism it did not run is the exact shape this gate exists to mark.
  #
  # Measured against the same corpus as Groups 1-2 plus the 13 findings in
  # tests/test_pre_merge_nonblocking.bats that must stay unflagged (the
  # test-54 "careful phrasing" set and a style-finding set): 6/6 of the real
  # false findings flag, 0/13 legitimate findings do. Re-run that measurement
  # before adding anything here -- broad terms like "treats" or "resolves to"
  # were rejected for catching careful phrasing.
  "process.argv"
  "argv["
  "off-by-one"
  "word-splitting"
  "word splitting"
  "will be skipped"
  "is skipped"
  "only runs"
  "does not run"
  "never fires"
  "silently drop"
  "silently lose"
  "silently lost"
  "silently swallow"
  "silently ignore"
  "silently fail"
  "silently succeed"
  # These two are broad on purpose. "this guard avoids false positives in
  # the rate limiter" does flag -- but that sentence IS a claim about how
  # something behaves, which is the target. The gate only labels and
  # annotates; it never suppresses. Asking a behavioral claim to show its
  # check is the intended outcome.
  "false positive"
  "false negative"
  "no such flag"
  "no such option"
  "no such version"
  "no such release"
  "has no v"
  "produce an empty"
  "returns an empty"
)

# Does this finding assert that something is factually incorrect/broken?
# Args: title details
# Returns 0 (true) on a match, 1 otherwise.
_asserts_incorrectness() {
  local haystack
  haystack=$(printf '%s\n%s' "${1:-}" "${2:-}" | { tr '[:upper:]' '[:lower:]' || true; })

  local marker
  for marker in "${_VERIFY_ASSERTION_MARKERS[@]}"; do
    # -F: the markers are fixed strings, and the haystack is model-authored
    # text that must never be read as a pattern (or as anything else — it is
    # passed on stdin, never interpolated into a command).
    if printf '%s' "${haystack}" | grep -qF -- "${marker}"; then
      return 0
    fi
  done
  return 1
}

# Prepend the "unverified claim" caveat to an issue body.
_unverified_caveat_body() {
  local body="$1"
  printf '%s\n' "> [!WARNING]"
  printf '%s\n' "> **Unverified claim.** This finding asserts that something is"
  printf '%s\n' "> incorrect, broken, or nonexistent, but carries no \`VERIFIED:\`"
  printf '%s\n' "> field recording a command that was actually run to check it."
  printf '%s\n' "> Confirm the assertion against reality before acting on it — several"
  printf '%s\n' "> such findings have turned out to be false."
  printf '%s\n' ">"
  printf '%s\n' "> Run the check before you fix anything. If the claim is about how a"
  printf '%s\n' "> tool or runtime behaves, it is usually one command — and if it is"
  printf '%s\n' "> wrong, close this issue with the output rather than changing code."
  printf '%s\n' ""
  printf '%s\n' "${body}"
}

# Append the "## Verification" section to an issue body.
_verification_section_body() {
  local body="$1"
  local verified="$2"
  printf '%s\n' "${body}"
  printf '%s\n' ""
  printf '%s\n' "## Verification"
  printf '%s\n' ""
  printf '%s\n' "The reviewer recorded the following command and output as support"
  printf '%s\n' "for this finding:"
  printf '%s\n' ""
  printf '%s\n' '```'
  printf '%s\n' "${verified}"
  printf '%s\n' '```'
}

# Parse a single issue block and create the GH issue (or fallback file).
_process_issue_block() {
  local block="$1"
  local pending_dir="$2"

  [[ -n "${block}" ]] || return 0

  local title source location details verified=""
  _parse_issue_fields "${block}" title source location details verified

  [[ -n "${title}" ]] || return 0

  # Dedup gate (#328): skip filing when an OPEN issue already tracks this
  # same finding. Fails open — see _find_duplicate_open_issue.
  local dup="" dup_num dup_url
  if declare -F _find_duplicate_open_issue >/dev/null 2>&1 &&
    declare -F _load_open_issues >/dev/null 2>&1; then
    # Prime the open-issue cache in THIS shell (not inside the command
    # substitution below, where the assignment would be lost to a subshell).
    _load_open_issues
    dup=$(_find_duplicate_open_issue "${title}" "${location}")
  fi
  if [[ -n "${dup}" ]]; then
    dup_num="${dup%%$'\t'*}"
    dup_url="${dup#*$'\t'}"
    log_success "Skipped duplicate finding: ${title}"
    log_success "  -> already tracked by #${dup_num} (${dup_url})"
    return 0
  fi

  # Determine labels
  local labels="tech-debt"
  if needs_security_label "${location}"; then
    labels="tech-debt,security"
  fi

  # Build issue body
  local body
  body=$(build_issue_body "${title}" "${source}" "${location}" "${details}")

  # Verifiable-claims gate (#328 gate 3). Annotates only — never suppresses,
  # and every branch here is wrapped so a failure still leaves ${body} and
  # ${labels} usable and the filing proceeds untouched.
  local unverified_label=false
  if [[ -n "${verified}" ]]; then
    if declare -F _verification_section_body >/dev/null 2>&1; then
      local _body_with_verification
      if _body_with_verification=$(_verification_section_body "${body}" "${verified}" 2>/dev/null); then
        body="${_body_with_verification}"
      fi
    fi
  elif declare -F _asserts_incorrectness >/dev/null 2>&1 &&
    _asserts_incorrectness "${title}" "${details}" 2>/dev/null; then
    if declare -F _unverified_caveat_body >/dev/null 2>&1; then
      local _body_with_caveat
      if _body_with_caveat=$(_unverified_caveat_body "${body}" 2>/dev/null); then
        body="${_body_with_caveat}"
        unverified_label=true
      fi
    fi
  fi
  if [[ "${unverified_label}" == true ]]; then
    labels="${labels},unverified"
  fi

  # Attempt to create GitHub issue — but only if the repo actually has
  # Issues enabled (#180). Repos with Issues disabled make `gh issue create`
  # fail loudly on every finding; skip straight to the fallback-file path
  # instead so a review with many findings doesn't spam stderr.
  # Use a temp file for stderr so gh warnings/upgrade notices don't contaminate
  # issue_url (same pattern as _fetch_pr_json).
  local issue_url gh_stderr_file gh_err="" created=false
  gh_stderr_file=$(mktemp)
  if _repo_has_issues_enabled; then
    if issue_url=$(command gh issue create \
      --repo "${REPO_OWNER}/${REPO_NAME}" \
      --title "${title}" \
      --body "${body}" \
      --label "${labels}" 2>"${gh_stderr_file}"); then
      created=true
    else
      gh_err=$(cat "${gh_stderr_file}")
    fi
  else
    gh_err="GitHub Issues are disabled for ${REPO_OWNER}/${REPO_NAME}"
  fi
  rm -f "${gh_stderr_file}"

  if [[ "${created}" == true ]]; then
    log_success "Created tracking issue: ${title}"
    log_success "  -> ${issue_url}"
  else
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
