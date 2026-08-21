#!/usr/bin/env bats
# Tests for non-blocking issue parsing and creation in lib-review-issues.sh
#
# Run: bats ~/.claude/tests/test_pre_merge_nonblocking.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/lib-review-issues.sh"

# Suppress log output in tests (exported so eval'd functions can call them)
log_info() { :; }
export -f log_info
log_warn() { :; }
export -f log_warn
log_success() { :; }
export -f log_success
log_error() { :; }
export -f log_error

# Variables used by build_issue_body tests; declared/exported at file scope so
# static analysis sees their use, then reassigned per-test without re-exporting.
export PR_NUMBER="" PR_TITLE="" REPO_OWNER="" REPO_NAME=""
# Variables used by create_nonblocking_issues tests; same pattern.
export GH_CALLS_FILE="" PENDING_ISSUES_DIR="" OSASCRIPT_CALLS_FILE=""

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Load only the named function from the script using sed range matching.
# CONSTRAINT: functions extracted by this helper must not have a bare `}` on
# its own line (matching /^}$/) inside their bodies — e.g. no unindented
# nested closing braces. The sed range stops at the first such line.
# Heredocs and awk blocks work correctly as long as their closing delimiters
# are indented or use non-`}` terminators.
_load_fn() {
  local fn_name="$1"
  local func_def
  func_def=$(sed -n "/^${fn_name}()/,/^}$/p" "${SCRIPT}")
  eval "${func_def}"
}

# --- parse_nonblocking_issues ---

@test "parse_nonblocking_issues: returns empty when no NON_BLOCKING_ISSUE block" {
  _load_fn parse_nonblocking_issues
  local input="VERDICT: SAFE_TO_MERGE

All review comments appear resolved."
  result=$(parse_nonblocking_issues "${input}")
  [[ -z "${result}" ]]
}

@test "parse_nonblocking_issues: parses single block" {
  _load_fn parse_nonblocking_issues
  local input="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Consider adding input validation
SOURCE: code-reviewer
LOCATION: src/api/handler.ts:42
DETAILS: The handler does not validate the 'limit' parameter. While the current
callers are trusted, adding validation would prevent future misuse.
END_ISSUE"
  result=$(parse_nonblocking_issues "${input}")
  echo "${result}" | grep -q "TITLE: Consider adding input validation"
}

@test "parse_nonblocking_issues: parses multiple blocks" {
  _load_fn parse_nonblocking_issues
  local input="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: First issue
SOURCE: Seer
LOCATION: src/auth/jwt.ts:10
DETAILS: Something here.
END_ISSUE

NON_BLOCKING_ISSUE:
TITLE: Second issue
SOURCE: code-reviewer
LOCATION: general
DETAILS: Something else.
END_ISSUE"
  result=$(parse_nonblocking_issues "${input}")
  count=$(echo "${result}" | grep -c "^TITLE:" || true)
  [[ "${count}" -eq 2 ]]
}

@test "parse_nonblocking_issues: handles DETAILS with colons" {
  _load_fn parse_nonblocking_issues
  local input="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Check config key
SOURCE: Seer
LOCATION: config/app.ts:5
DETAILS: Key 'foo: bar' is unusual. Consider: renaming it or documenting it.
END_ISSUE"
  result=$(parse_nonblocking_issues "${input}")
  echo "${result}" | grep -q "DETAILS:"
}

@test "parse_nonblocking_issues: returns empty on BLOCK_MERGE verdict" {
  _load_fn parse_nonblocking_issues
  local input="VERDICT: BLOCK_MERGE

ISSUE: Critical bug
SOURCE: CI
LOCATION: src/index.ts:1
STATUS: UNRESOLVED
DETAILS: Tests failing."
  result=$(parse_nonblocking_issues "${input}")
  [[ -z "${result}" ]]
}

# --- build_issue_body ---

@test "build_issue_body: includes PR number and title" {
  _load_fn build_issue_body
  PR_NUMBER="99"
  PR_TITLE="My test PR"
  REPO_OWNER="testorg"
  REPO_NAME="testrepo"
  result=$(build_issue_body "Fix the thing" "Seer" "src/auth/jwt.ts:42" "Seer flagged a potential issue.")
  echo "${result}" | grep -q "#99"
  echo "${result}" | grep -q "My test PR"
}

@test "build_issue_body: includes source and location" {
  _load_fn build_issue_body
  PR_NUMBER="1"
  PR_TITLE="PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  result=$(build_issue_body "Some title" "Seer" "src/auth/session.ts:10" "Details here.")
  echo "${result}" | grep -q "Seer"
  echo "${result}" | grep -q "src/auth/session.ts:10"
}

@test "build_issue_body: includes details" {
  _load_fn build_issue_body
  PR_NUMBER="1"
  PR_TITLE="PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  result=$(build_issue_body "Title" "source" "general" "This is the detail text.")
  echo "${result}" | grep -q "This is the detail text."
}

# --- needs_security_label ---

@test "needs_security_label: returns true for auth path" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  needs_security_label "src/auth/jwt.ts:42"
}

@test "needs_security_label: returns false for general location" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  run ! needs_security_label "general"
}

@test "needs_security_label: returns true for payment path" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  needs_security_label "src/payment/stripe.ts:5"
}

# --- create_nonblocking_issues ---

@test "create_nonblocking_issues: calls gh issue create for each parsed issue" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Mock gh: record calls, succeed
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "create_nonblocking_issues: writes fallback file when gh fails" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending-issues"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Mock gh: label create succeeds, issue create fails
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"label create"* ]]; then exit 0; fi
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Something non blocking
SOURCE: code-reviewer
LOCATION: general
DETAILS: Not urgent but worth noting.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  # A fallback file should exist in PENDING_ISSUES_DIR
  local found=0
  for f in "${PENDING_ISSUES_DIR}/55-"*; do [[ -f "${f}" ]] && found=1; done
  [[ "${found}" -eq 1 ]]
}

@test "create_nonblocking_issues: no-op when no NON_BLOCKING_ISSUE blocks" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

All review comments appear resolved."

  create_nonblocking_issues "${analysis}"

  # gh should NOT have been called for issue create
  [[ ! -f "${GH_CALLS_FILE}" ]] || ! grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "create_nonblocking_issues: applies security label for auth path" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Auth concern
SOURCE: Seer
LOCATION: src/auth/session.ts:99
DETAILS: Minor auth issue.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "security" "${GH_CALLS_FILE}"
}

# --- is_corporate_repo ---

@test "is_corporate_repo: true for beacon-biosignals" {
  _load_fn is_corporate_repo
  REPO_OWNER="beacon-biosignals"
  is_corporate_repo
}

@test "is_corporate_repo: false for a personal repo" {
  _load_fn is_corporate_repo
  REPO_OWNER="andrewrich"
  run ! is_corporate_repo
}

# --- is_self_authored ---

@test "is_self_authored: true when PR_NUMBER is unset (commit-level review)" {
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  PR_NUMBER=""
  is_self_authored
}

@test "is_self_authored: true when PR author matches the authenticated gh login" {
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  PR_NUMBER="10"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) echo "andrew" ;;
  *"api user"*) echo "andrew" ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  is_self_authored
}

@test "is_self_authored: false when PR author differs from the authenticated gh login" {
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  PR_NUMBER="10"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) echo "teammate" ;;
  *"api user"*) echo "andrew" ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  run ! is_self_authored
}

@test "is_self_authored: false on gh lookup failure (fail toward PR-comment path)" {
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  PR_NUMBER="10"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  run ! is_self_authored
}

# --- create_nonblocking_issues: corporate-repo dispatch ---

@test "create_nonblocking_issues: corporate + self-authored files an Apple Note, not a gh issue" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _escape_for_applescript
  _load_fn create_apple_note_issue
  _load_fn _process_issue_block_apple_note
  _load_fn create_nonblocking_issues
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER=""
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  OSASCRIPT_CALLS_FILE="${MOCK_DIR}/osascript_calls"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  cat >"${MOCK_DIR}/osascript" <<'EOF'
#!/usr/bin/env bash
echo "called" >> "${OSASCRIPT_CALLS_FILE}"
cat >/dev/null
exit 0
EOF
  chmod +x "${MOCK_DIR}/osascript"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  [[ -f "${OSASCRIPT_CALLS_FILE}" ]]
  [[ ! -f "${GH_CALLS_FILE}" ]] || ! grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "create_nonblocking_issues: corporate + self-authored (PR context) files an Apple Note via a real is_self_authored lookup" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _escape_for_applescript
  _load_fn create_apple_note_issue
  _load_fn _process_issue_block_apple_note
  _load_fn create_nonblocking_issues
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  # Unlike the PR_NUMBER="" case above, this exercises the actual
  # `gh pr view` / `gh api user` comparison inside is_self_authored.
  PR_NUMBER="10"
  PR_TITLE="My own PR"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  OSASCRIPT_CALLS_FILE="${MOCK_DIR}/osascript_calls"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"pr view"*) echo "andrew" ;;
  *"api user"*) echo "andrew" ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  cat >"${MOCK_DIR}/osascript" <<'EOF'
#!/usr/bin/env bash
echo "called" >> "${OSASCRIPT_CALLS_FILE}"
cat >/dev/null
exit 0
EOF
  chmod +x "${MOCK_DIR}/osascript"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  [[ -f "${OSASCRIPT_CALLS_FILE}" ]]
  grep -q "pr view" "${GH_CALLS_FILE}"
  run ! grep -q "issue create" "${GH_CALLS_FILE}"
  run ! grep -q "pr comment" "${GH_CALLS_FILE}"
}

@test "create_nonblocking_issues: corporate + not-self posts a PR comment, not a gh issue" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _format_issue_bullet
  _load_fn post_nonblocking_as_pr_comment
  _load_fn create_nonblocking_issues
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="42"
  PR_TITLE="Teammate PR"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"pr view"*) echo "teammate" ;;
  *"api user"*) echo "andrew" ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "pr comment" "${GH_CALLS_FILE}"
  run ! grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "create_nonblocking_issues: corporate + not-self falls back to a pending file when gh pr comment fails" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _format_issue_bullet
  _load_fn post_nonblocking_as_pr_comment
  _load_fn create_nonblocking_issues
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="42"
  PR_TITLE="Teammate PR"
  REPO_OWNER="beacon-biosignals"
  REPO_NAME="repo"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending-issues"

  # Mock gh: author lookup succeeds (not-self), but `pr comment` itself fails
  # (e.g. auth expired, rate limit) — the finding must not be silently lost.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*) echo "teammate"; exit 0 ;;
  *"api user"*) echo "andrew"; exit 0 ;;
  *"pr comment"*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  # Assert on content, not just the filename shape, so this doesn't depend
  # on how _write_pending_issue_file composes its prefix/slug.
  local found=0
  for f in "${PENDING_ISSUES_DIR}"/*; do
    [[ -f "${f}" ]] || continue
    grep -q "Fix the thing" "${f}" && found=1
  done
  [[ "${found}" -eq 1 ]]
}

@test "create_nonblocking_issues: personal repo files a gh issue regardless of authorship" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="42"
  PR_TITLE="Teammate PR"
  REPO_OWNER="andrewrich"
  REPO_NAME="repo"

  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Mock gh: pr author differs from authenticated login, but personal repos
  # never consult authorship — gh issue create should still fire.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"pr view"*) echo "teammate" ;;
  *"api user"*) echo "andrew" ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "issue create" "${GH_CALLS_FILE}"
}

# --- _escape_for_applescript ---

@test "_escape_for_applescript: escapes backslash, quote, dollar, and backtick" {
  _load_fn _escape_for_applescript
  result=$(_escape_for_applescript "a\\b\"c\$d\`e")
  [[ "${result}" == "a\\\\b\\\"c\\\$d\\\`e" ]]
}

# --- create_apple_note_issue: heredoc injection safety ---
# Regression test for a real finding from pre-push whole-codebase review:
# the unquoted `osascript <<EOF` heredoc lets bash expand $()/backticks in
# review-agent-supplied TITLE/DETAILS before osascript ever sees them.

@test "create_apple_note_issue: does not execute shell commands embedded in title/body" {
  _load_fn _escape_for_applescript
  _load_fn create_apple_note_issue

  local marker="${MOCK_DIR}/should-not-exist"
  local osascript_stdin="${MOCK_DIR}/osascript_stdin"

  cat >"${MOCK_DIR}/osascript" <<EOF
#!/usr/bin/env bash
cat > "${osascript_stdin}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/osascript"

  local malicious_title="Title \$(touch ${marker}) end"
  local malicious_body="body \`touch ${marker}\` text"

  create_apple_note_issue "${malicious_title}" "${malicious_body}"

  [[ ! -f "${marker}" ]]
  grep -q "\\\\\\\$(touch" "${osascript_stdin}"
  grep -q "\\\\\`touch" "${osascript_stdin}"
}

# --- _repo_has_issues_enabled / _process_issue_block gh-issue-create guard ---
# Regression tests for #180: a repo with GitHub Issues disabled made every
# non-blocking finding attempt (and fail) `gh issue create`, producing up
# to 30 noisy stderr warnings per push. The guard checks
# `gh api repos/{owner}/{repo} --jq '.has_issues'` once per run (cached)
# and skips straight to the fallback-file path when it's explicitly false.

@test "_process_issue_block: skips gh issue create when GitHub Issues are disabled" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending-issues"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Mock gh: the has_issues probe explicitly reports issues disabled;
  # `gh issue create` would fail loudly if it were ever invoked.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"api repos/"*) echo "false"; exit 0 ;;
  *"issue create"*) echo "gh error: repository has disabled issues" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Something to fix later.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  # NOTE: intentionally not `! grep -q ...` (or `run ! grep -q ...`) as a
  # standalone statement. `create_nonblocking_issues` calls functions that
  # use `if` internally, which — due to a well-known bash quirk — leaves
  # `errexit` semantics unreliable for the rest of this test body: an
  # intermediate failing statement no longer aborts execution the way a
  # fresh shell would. Bats only reliably observes the exit status of the
  # test body's FINAL statement, so both conditions are folded into one.
  local issue_create_called=0
  grep -q "issue create" "${GH_CALLS_FILE}" && issue_create_called=1

  local found=0
  for f in "${PENDING_ISSUES_DIR}/55-"*; do [[ -f "${f}" ]] && found=1; done

  [[ "${issue_create_called}" -eq 0 && "${found}" -eq 1 ]]
}

@test "_process_issue_block: caches the has_issues check across multiple findings in one run" {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _repo_has_issues_enabled
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="55"
  PR_TITLE="Test PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending-issues"
  API_CALLS_FILE="${MOCK_DIR}/api_calls"
  export API_CALLS_FILE

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"api repos/"*) echo x >> "${API_CALLS_FILE}"; echo "false"; exit 0 ;;
esac
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: First finding
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: First.
END_ISSUE

NON_BLOCKING_ISSUE:
TITLE: Second finding
SOURCE: code-reviewer
LOCATION: general
DETAILS: Second.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local api_call_count
  api_call_count=$(wc -l <"${API_CALLS_FILE}")
  [[ "${api_call_count}" -eq 1 ]]
}

@test "_repo_has_issues_enabled: fails open (treats as enabled) when the probe errors or is ambiguous" {
  _load_fn _repo_has_issues_enabled

  REPO_OWNER="org"
  REPO_NAME="repo"

  # Mock gh: api call fails outright (network error, auth issue, etc.) —
  # must NOT be mistaken for an explicit "issues disabled" response.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  _repo_has_issues_enabled
}

# --- _parse_issue_fields: END_ISSUE stop-set (#333) ---
# In the normal flow parse_nonblocking_issues() has already consumed the
# END_ISSUE terminator, so these blocks never reach _parse_issue_fields with it
# attached. The stop-set entry is defensive hardening against a caller that
# doesn't strip it first; these tests pin that behavior so it can't regress
# back into a silent call-site dependency.

@test "_parse_issue_fields: DETAILS stops at a trailing END_ISSUE" {
  _load_fn _parse_issue_fields
  local block="TITLE: Something
SOURCE: code-reviewer
LOCATION: src/a.ts:1
DETAILS: First detail line.
Second detail line.
END_ISSUE"

  local t s l d
  _parse_issue_fields "${block}" t s l d

  [[ "${d}" == "First detail line.
Second detail line." ]]
}

@test "_parse_issue_fields: VERIFIED stops at a trailing END_ISSUE" {
  _load_fn _parse_issue_fields
  local block="TITLE: Something
SOURCE: code-reviewer
LOCATION: src/a.ts:1
DETAILS: A detail.
VERIFIED: gh api some/path -> 404
second line of evidence
END_ISSUE"

  local t s l d v
  _parse_issue_fields "${block}" t s l d v

  [[ "${v}" == "gh api some/path -> 404
second line of evidence" ]]
  # DETAILS still terminates at the VERIFIED: header, as before.
  [[ "${d}" == "A detail." ]]
}

@test "_parse_issue_fields: END_ISSUE-stripped blocks parse exactly as before" {
  # Regression guard: the stop-set addition must not change the normal path,
  # where parse_nonblocking_issues() has already removed the terminator.
  _load_fn _parse_issue_fields
  local block="TITLE: Something
SOURCE: code-reviewer
LOCATION: src/a.ts:1
DETAILS: First detail line.
Second detail line.
VERIFIED: a command"

  local t s l d v
  _parse_issue_fields "${block}" t s l d v

  [[ "${t}" == "Something" ]]
  [[ "${d}" == "First detail line.
Second detail line." ]]
  [[ "${v}" == "a command" ]]
}

# --- dedup against existing open issues (#328) ---
# The reviewer files one issue per finding with no memory of what it already
# filed; in the field that produced 24 auto-filed issues in a day, the biggest
# cluster being repeat filings of one settled objection. _process_issue_block
# now skips a finding when an OPEN issue already tracks the same file path with
# an overlapping title. Fails open: any lookup failure files as before.

# Common loader for the dedup tests.
_load_dedup_fns() {
  _load_fn is_security_critical
  _load_fn needs_security_label
  _load_fn is_corporate_repo
  _load_fn _cached_gh_login
  _load_fn is_self_authored
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
  _load_fn _parse_issue_fields
  _load_fn _write_pending_issue_file
  _load_fn _repo_has_issues_enabled
  _load_fn _dedup_title_tokens
  _load_fn _dedup_location_path
  _load_fn _load_open_issues
  _load_fn _find_duplicate_open_issue
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block
  _load_fn _format_issue_section
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue
  # Constants the extracted functions reference (not picked up by _load_fn,
  # which only extracts function definitions).
  _DEDUP_MIN_TOKEN_OVERLAP=2
  _DEDUP_STOPWORDS='this|that|with|from|when|then|than|were|will|would|should|could|have|been|does|into|only|also|same|such|they|them|there|where|which|while|about|after|before|being|other|using|used|make|made|more|most|some'
  _OPEN_ISSUES_CACHE=""
  _OPEN_ISSUES_STATE=""
  _HAS_ISSUES_CACHE=""
  # Deliberately small so the truncation tests can hit the limit with a
  # two-row payload instead of generating a thousand of them; the production
  # value lives in lib-review-issues.sh and is asserted separately below.
  _OPEN_ISSUES_LIMIT=2
}

# Mock gh whose `issue list` returns the given TSV rows and whose
# `issue create` is recorded. $1 = TSV payload (may be empty).
_mock_gh_with_open_issues() {
  export DEDUP_LIST_PAYLOAD="$1"
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"api repos/"*) echo "true"; exit 0 ;;
  *"issue list"*) printf '%s' "${DEDUP_LIST_PAYLOAD}"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"
}

@test "dedup: finding matching an existing open issue is NOT filed" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Existing open issue: the same objection, at a different line number.
  _mock_gh_with_open_issues \
"193	https://github.com/org/repo/issues/193	Reusable workflow reference moved from immutable SHA pin to mutable tag	.github/workflows/claude.yml:23"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: claude.yml switched from immutable commit-SHA pin to mutable named tag
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:31
DETAILS: Same pinning objection, rephrased.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local created=0
  grep -q "issue create" "${GH_CALLS_FILE}" && created=1
  [[ "${created}" -eq 0 ]]
}

@test "dedup: a genuinely new finding is still filed" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Open issue is in a different file entirely.
  _mock_gh_with_open_issues \
"193	https://github.com/org/repo/issues/193	Reusable workflow reference moved from immutable SHA pin to mutable tag	.github/workflows/claude.yml:23"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Handler does not validate the limit parameter
SOURCE: Seer
LOCATION: src/api/handler.ts:10
DETAILS: Unvalidated input.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "dedup: two distinct findings in the SAME file are both filed" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # Same path as the new finding, but no meaningful title overlap — path
  # alone must not be enough to suppress.
  _mock_gh_with_open_issues \
"193	https://github.com/org/repo/issues/193	Reusable workflow reference moved from immutable SHA pin to mutable tag	.github/workflows/claude.yml:23"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Concurrency group missing, queued runs cancel each other
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:80
DETAILS: Unrelated concern in the same file.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "dedup: search failure files the issue anyway (fails open)" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # `gh issue list` fails outright (network/auth/rate limit). The finding is
  # a textual duplicate of a real open issue, but a failed lookup must never
  # silently suppress it.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
case "$*" in
  *"api repos/"*) echo "true"; exit 0 ;;
  *"issue list"*) echo "error: could not connect" >&2; exit 1 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Reusable workflow reference moved from immutable SHA pin to mutable tag
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:23
DETAILS: Would have been deduped had the lookup succeeded.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "dedup: closed issues do not suppress a new filing" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # The listing is scoped to --state open, so a matching CLOSED issue simply
  # never appears in the payload; the finding must file.
  _mock_gh_with_open_issues ""

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Reusable workflow reference moved from immutable SHA pin to mutable tag
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:23
DETAILS: Prior issue on this was closed.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local created=0
  grep -q "issue create" "${GH_CALLS_FILE}" && created=1
  local queried_open=0
  grep -q -- "--state open" "${GH_CALLS_FILE}" && queried_open=1
  [[ "${created}" -eq 1 && "${queried_open}" -eq 1 ]]
}

@test "dedup: title with shell metacharacters does not execute anything" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PWNED_FILE="${MOCK_DIR}/pwned"
  export PWNED_FILE

  _mock_gh_with_open_issues ""

  # Title and location both carry command-substitution attempts, backticks
  # and quotes. None may be evaluated by the dedup path.
  local analysis='VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: broken $(touch "${PWNED_FILE}") and `touch "${PWNED_FILE}"` quoted'"'"'s
SOURCE: code-reviewer
LOCATION: src/$(touch "${PWNED_FILE}").ts:1
DETAILS: Injection attempt.
END_ISSUE'

  create_nonblocking_issues "${analysis}"

  [[ ! -e "${PWNED_FILE}" ]]
}

@test "dedup: open-issue listing is fetched once across many findings" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  _mock_gh_with_open_issues ""

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: First finding here
SOURCE: Seer
LOCATION: src/one.ts:1
DETAILS: First.
END_ISSUE

NON_BLOCKING_ISSUE:
TITLE: Second finding here
SOURCE: Seer
LOCATION: src/two.ts:2
DETAILS: Second.
END_ISSUE

NON_BLOCKING_ISSUE:
TITLE: Third finding here
SOURCE: Seer
LOCATION: src/three.ts:3
DETAILS: Third.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local list_calls
  list_calls=$(grep -c "issue list" "${GH_CALLS_FILE}" || true)
  [[ "${list_calls}" -eq 1 ]]
}

# --- open-issue listing truncation (#330) ---
# `gh issue list --limit N` returns at most N rows and gives no signal that it
# clipped anything, so a repo with more open issues than the limit would let
# duplicates through with no explanation. The listing now asks for gh's maximum
# and warns when the row count lands on the limit.

# Capture log_warn output for the duration of one test. The file-scope
# log_warn is a silent no-op; this shadows it locally.
_capture_warnings() {
  WARN_FILE="${MOCK_DIR}/warnings"
  export WARN_FILE
  log_warn() { printf '%s\n' "$*" >>"${WARN_FILE}"; }
}

@test "truncation: production limit is gh's documented maximum" {
  # Guards against the limit being quietly lowered back toward the old 200.
  # Read from the real library rather than the test's local override.
  local limit
  limit=$(bash -c 'source "$1"; printf "%s" "${_OPEN_ISSUES_LIMIT}"' _ "${SCRIPT}")
  [[ "${limit}" -eq 1000 ]]
}

@test "truncation: listing at the limit warns that dedup may be incomplete" {
  _load_dedup_fns
  _capture_warnings
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  # _OPEN_ISSUES_LIMIT is 2 in tests, so a two-row payload is "full".
  _mock_gh_with_open_issues \
"1	https://github.com/org/repo/issues/1	First open issue title here	src/a.ts:1
2	https://github.com/org/repo/issues/2	Second open issue title here	src/b.ts:2"

  _load_open_issues

  # Warned ...
  grep -q "dedup may be incomplete" "${WARN_FILE}"
  # ... but the listing is still usable, not downgraded to "error".
  [[ "${_OPEN_ISSUES_STATE}" == "ok" ]]
  [[ -n "${_OPEN_ISSUES_CACHE}" ]]
}

@test "truncation: a listing under the limit warns about nothing" {
  _load_dedup_fns
  _capture_warnings
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  _mock_gh_with_open_issues \
"1	https://github.com/org/repo/issues/1	First open issue title here	src/a.ts:1"

  _load_open_issues

  [[ ! -e "${WARN_FILE}" ]]
  [[ "${_OPEN_ISSUES_STATE}" == "ok" ]]
}

@test "truncation: an empty listing warns about nothing" {
  _load_dedup_fns
  _capture_warnings
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  _mock_gh_with_open_issues ""

  _load_open_issues

  [[ ! -e "${WARN_FILE}" ]]
  [[ "${_OPEN_ISSUES_STATE}" == "ok" ]]
}

@test "truncation: the requested limit is what gh is actually asked for" {
  _load_dedup_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"

  _mock_gh_with_open_issues ""
  _load_open_issues

  grep -q -- "--limit ${_OPEN_ISSUES_LIMIT}" "${GH_CALLS_FILE}"
}

# --- verifiable-claims gate (#328 gate 3) ---

_load_gate3_fns() {
  # Marker array (not a function, so _load_fn does not pick it up). Get the
  # REAL array by sourcing the library, rather than re-extracting its text
  # with a sed range (#335) — a pattern match on the source silently yields an
  # empty or partial array the moment the array's formatting changes, and an
  # empty marker list makes every gate3 assertion test pass vacuously.
  # Sourcing is safe here: lib-review-issues.sh is function definitions plus a
  # source guard and a few constant assignments, with no top-level code that
  # runs commands, exits, or touches the filesystem. `_LIB_REVIEW_ISSUES_LOADED`
  # is cleared first so a second test in the same shell isn't no-op'd by the
  # guard.
  unset _LIB_REVIEW_ISSUES_LOADED
  source "${SCRIPT}"
  # _load_fn extraction still runs afterwards, so these tests keep exercising
  # the same individually-extracted definitions they always did.
  _load_dedup_fns
  _load_fn _asserts_incorrectness
  _load_fn _unverified_caveat_body
  _load_fn _verification_section_body
}

# gh mock that records the full argv of each call, one call per line, so
# tests can assert on --label and --body values.
_mock_gh_recording() {
  export DEDUP_LIST_PAYLOAD=""
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${*//$'\n'/ }" >> "${GH_CALLS_FILE}"
case "$*" in
  *"api repos/"*) echo "true"; exit 0 ;;
  *"issue list"*) printf '%s' "${DEDUP_LIST_PAYLOAD}"; exit 0 ;;
  *"issue create"*) echo "https://github.com/org/repo/issues/999"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"
}

@test "gate3: assertion without VERIFIED is still filed AND labeled unverified" {
  _load_gate3_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  _mock_gh_recording

  # This is the shape of github-workflows#131: a flat assertion about what a
  # SHA resolves to, with no command recorded.
  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Pinned SHA does not match the annotated version
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:23
DETAILS: The SHA belongs to the v4.x release line, and v7.0.1 does not exist for this action.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local create_line
  create_line=$(grep "issue create" "${GH_CALLS_FILE}")
  # Filed (fail open — the gate annotates, never suppresses) ...
  [[ -n "${create_line}" ]]
  # ... with the unverified label added alongside the existing ones ...
  echo "${create_line}" | grep -q "tech-debt,unverified"
  # ... and the caveat visible on the item itself. Batched filing renders
  # findings as checklist items, so the per-finding warning is an inline
  # marker rather than a body-level blockquote banner.
  echo "${create_line}" | grep -q "unverified claim"
}

@test "gate3: assertion WITH VERIFIED is filed clean, with a Verification section" {
  _load_gate3_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  _mock_gh_recording

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Pinned SHA does not match the annotated version
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:23
DETAILS: The comment claims v7.0.1 but the SHA does not exist under that tag.
VERIFIED: gh api repos/actions/checkout/git/ref/tags/v7.0.1 -> HTTP 404 Not Found
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local create_line
  create_line=$(grep "issue create" "${GH_CALLS_FILE}")
  [[ -n "${create_line}" ]]
  # The supporting command is surfaced on the item ...
  echo "${create_line}" | grep -q "verified:"
  echo "${create_line}" | grep -q "HTTP 404 Not Found"
  # ... and NO unverified label or caveat, since the claim carries support.
  ! echo "${create_line}" | grep -q "tech-debt,unverified"
  ! echo "${create_line}" | grep -q "unverified claim"
  # The VERIFIED: line must not leak into DETAILS / "What was flagged".
  ! echo "${create_line}" | grep -q "VERIFIED: gh api"
}

@test "gate3: a non-assertion finding is untouched" {
  _load_gate3_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  _mock_gh_recording

  # Hedged, suggestive phrasing — makes no factual claim about external
  # state, so it needs no VERIFIED: field and must not be labelled.
  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Consider extracting the retry loop into a helper
SOURCE: code-reviewer
LOCATION: src/api/handler.ts:42
DETAILS: The retry logic is duplicated in three places. Extracting it would reduce drift.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local create_line
  create_line=$(grep "issue create" "${GH_CALLS_FILE}")
  [[ -n "${create_line}" ]]
  ! echo "${create_line}" | grep -q "unverified"
  ! echo "${create_line}" | grep -q "Unverified claim"
  ! echo "${create_line}" | grep -q "## Verification"
}

@test "gate3: title/details/VERIFIED with shell metacharacters execute nothing" {
  _load_gate3_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PWNED_FILE="${MOCK_DIR}/pwned_gate3"
  export PWNED_FILE
  _mock_gh_recording

  # All three model-authored fields carry command substitution, backticks and
  # quotes, AND the block trips the assertion markers so the whole gate-3
  # code path runs over the hostile text.
  local analysis='VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: config $(touch "${PWNED_FILE}") is incorrect and `touch "${PWNED_FILE}"` is broken
SOURCE: code-reviewer
LOCATION: src/$(touch "${PWNED_FILE}").ts:1
DETAILS: The value $(touch "${PWNED_FILE}") does not exist; `touch "${PWNED_FILE}"` will fail.
VERIFIED: $(touch "${PWNED_FILE}") && `touch "${PWNED_FILE}"`
END_ISSUE'

  create_nonblocking_issues "${analysis}"

  [[ ! -e "${PWNED_FILE}" ]]
}

@test "gate3: failure inside the gate does not block filing (fails open)" {
  _load_gate3_fns
  PR_NUMBER="55"; PR_TITLE="Test PR"; REPO_OWNER="org"; REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  _mock_gh_recording

  # Simulate the gate's helpers being broken/absent at runtime. The filing
  # must proceed exactly as it did before gate 3 existed — a lost finding is
  # worse than an unannotated one.
  _asserts_incorrectness() { return 1; }
  _unverified_caveat_body() { return 1; }
  _verification_section_body() { return 1; }

  local analysis="VERDICT: SAFE_TO_MERGE

NON_BLOCKING_ISSUE:
TITLE: Pinned SHA does not match and the tag does not exist
SOURCE: code-reviewer
LOCATION: .github/workflows/claude.yml:23
DETAILS: This assertion is broken and will fail.
VERIFIED: some command output
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  local create_line
  create_line=$(grep "issue create" "${GH_CALLS_FILE}")
  # Filed, with the finding intact and the original labels unchanged.
  [[ -n "${create_line}" ]]
  echo "${create_line}" | grep -q "Pinned SHA does not match"
  ! echo "${create_line}" | grep -q "unverified"
}

@test "gate3: _asserts_incorrectness matches markers case-insensitively and only on real assertions" {
  _load_gate3_fns

  _asserts_incorrectness "The SHA is incorrect" ""
  _asserts_incorrectness "" "This IS WRONG in the general case"
  _asserts_incorrectness "Tag v7.0.1 does not exist" ""
  _asserts_incorrectness "The job never runs" ""
  ! _asserts_incorrectness "Consider extracting the retry loop" "Would reduce drift."
  ! _asserts_incorrectness "It is unclear whether this path is reachable" "May want to check."
}

@test "gate3: self-admitted-unverified phrasing is flagged (#337, github-workflows#148)" {
  _load_gate3_fns

  # The motivating case: a factual claim about bash escaping, with the
  # finding itself stating it was never checked. Filed anyway; turned out
  # to be wrong.
  _asserts_incorrectness \
    '`--model` argument now double-quoted in assembled claude_args string' \
    'The behavior change is real. But it differs from the pre-existing unquoted form and has not been tested in a live run.'

  _asserts_incorrectness "" "This has not been verified against the live API."
  _asserts_incorrectness "" "The mapping has not been confirmed on a real run."
  _asserts_incorrectness "" "The regex was not verified against the actual input."
  _asserts_incorrectness "" "This path has not been validated end to end."
}

@test "gate3: broad negative phrasing stays UNflagged (rejected #334 candidates)" {
  _load_gate3_fns

  # Measured against a 137-finding corpus: "is not" and "has no"
  # overwhelmingly catch the reviewer being CAREFUL, not asserting.
  # Flagging these would invert the gate's meaning.
  ! _asserts_incorrectness "" "This is not a correctness issue — capped PRs simply wait."
  ! _asserts_incorrectness "" "It is not currently vulnerable, but a future refactor could change that."
  ! _asserts_incorrectness "" "This is not a confirmed regression — it may be correct as written."
  ! _asserts_incorrectness "" "The --verbose flag has no observable effect."
  ! _asserts_incorrectness "" "This has no practical impact, but the directive is dead."

  # Phrases #334 proposed that never occur in the real corpus.
  ! _asserts_incorrectness "" "The entry is not present in the allowlist."
  ! _asserts_incorrectness "" "The helper cannot be found on PATH."
}

@test "gate3: behavior-mechanism claims are flagged (projectinsomnia #124/#128/#131/#132/#133/#137)" {
  _load_gate3_fns

  # Six findings in one session asserted how a tool or runtime BEHAVES,
  # from memory, and every one was false. None used Group 1 phrasing, so
  # none were labelled -- each cost a human a one-line command to disprove.
  _asserts_incorrectness "" "The commit message claims node receives the name via argv, but line 135 never extracts process.argv[1]."
  _asserts_incorrectness "" "if: failure() is scoped to the preceding step, so a failing audit will be skipped and the log is dropped."
  _asserts_incorrectness "" "GNU grep -w treats / as a word character, so @netlify/dev will produce false negatives."
  _asserts_incorrectness "" "The jq filter returns an empty array, causing the script to silently succeed."
  _asserts_incorrectness "" "The current released major is v4 — this action has no v7 release."
  _asserts_incorrectness "" "Those sections only render when credentials are configured; otherwise the page does not run that path."
}

@test "gate3: style and structure findings stay UNflagged" {
  _load_gate3_fns

  # Group 3 must not catch findings that make no factual claim about
  # external state -- those legitimately carry no VERIFIED: field.
  ! _asserts_incorrectness "" "The function is long and would read better split into two helpers."
  ! _asserts_incorrectness "" "Consider extracting this duplicated block into a shared helper."
  ! _asserts_incorrectness "" "This variable name is ambiguous; rename for clarity."
  ! _asserts_incorrectness "" "The comment density here is lower than the surrounding file."
  ! _asserts_incorrectness "" "Test coverage for the error path is missing."
  ! _asserts_incorrectness "" "This adds a second source of truth for the same list."
}

# --- _format_issue_section (batched filing, #388) ---

@test "_format_issue_section: renders a checklist item with title, source and location" {
  _load_fn _parse_issue_fields
  _load_fn _format_issue_section

  local block="TITLE: Fix the thing
SOURCE: Seer
LOCATION: src/a.ts:10
DETAILS: Some detail here."
  result=$(_format_issue_section "${block}")
  [[ "${result}" == *"- [ ] **Fix the thing**"* ]]
  [[ "${result}" == *"Seer"* ]]
  [[ "${result}" == *"src/a.ts:10"* ]]
  [[ "${result}" == *"Some detail here."* ]]
}

@test "_format_issue_section: returns nothing for an empty block" {
  _load_fn _parse_issue_fields
  _load_fn _format_issue_section
  result=$(_format_issue_section "")
  [[ -z "${result}" ]]
}

@test "_format_issue_section: returns nothing when TITLE is absent" {
  _load_fn _parse_issue_fields
  _load_fn _format_issue_section
  local block="SOURCE: Seer
LOCATION: src/a.ts:10
DETAILS: No title in this block."
  result=$(_format_issue_section "${block}")
  [[ -z "${result}" ]]
}

@test "_format_issue_section: collapses multi-line DETAILS into one line" {
  _load_fn _parse_issue_fields
  _load_fn _format_issue_section
  local block="TITLE: Multi
SOURCE: code-reviewer
LOCATION: src/b.ts:4
DETAILS: First line of detail.
Second line of detail."
  result=$(_format_issue_section "${block}")
  [[ "${result}" == *"First line of detail. Second line of detail."* ]]
}

@test "_format_issue_section: surfaces the VERIFIED command when present" {
  _load_fn _parse_issue_fields
  _load_fn _format_issue_section
  local block="TITLE: Checked thing
SOURCE: code-reviewer
LOCATION: src/c.ts:7
DETAILS: Detail.
VERIFIED: ran the suite and it failed"
  result=$(_format_issue_section "${block}")
  [[ "${result}" == *"ran the suite and it failed"* ]]
}

@test "_format_issue_section: marks an unverified assertion inline" {
  # _asserts_incorrectness reads the module-level _VERIFY_ASSERTION_MARKERS
  # array, so it needs the full-library loader rather than _load_fn.
  _load_gate3_fns
  _load_fn _format_issue_section
  local block="TITLE: Broken thing
SOURCE: code-reviewer
LOCATION: src/d.ts:9
DETAILS: This value is incorrect and must be changed."
  result=$(_format_issue_section "${block}")
  [[ "${result}" == *"unverified"* ]]
}

# --- create_batched_nonblocking_issue (#388) ---

@test "create_batched_nonblocking_issue: files exactly one issue for multiple findings" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="77"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local parsed="TITLE: First finding
SOURCE: Seer
LOCATION: src/a.ts:1
DETAILS: Detail one.
---ISSUE---
TITLE: Second finding
SOURCE: code-reviewer
LOCATION: src/b.ts:2
DETAILS: Detail two."

  create_batched_nonblocking_issue "${parsed}" "${PENDING_ISSUES_DIR}"

  local creates
  creates=$(grep -c "issue create" "${GH_CALLS_FILE}" || true)
  [[ "${creates}" -eq 1 ]]
}

@test "create_batched_nonblocking_issue: the single issue body contains every finding" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="78"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--body" ]]; then printf '%s' "$2" > "${MOCK_DIR}/body.txt"; fi
  shift
done
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local parsed="TITLE: Alpha finding
SOURCE: Seer
LOCATION: src/a.ts:1
DETAILS: Detail one.
---ISSUE---
TITLE: Beta finding
SOURCE: code-reviewer
LOCATION: src/b.ts:2
DETAILS: Detail two."

  create_batched_nonblocking_issue "${parsed}" "${PENDING_ISSUES_DIR}"

  # Assert against the --body argument specifically, not the whole gh call
  # line: a whole-line grep would also pass if the strings only appeared in
  # --title or --label, which is a weaker contract than intended (#388).
  grep -q "Alpha finding" "${MOCK_DIR}/body.txt"
  grep -q "Beta finding" "${MOCK_DIR}/body.txt"
}

@test "create_batched_nonblocking_issue: applies the security label when any finding is security-critical" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="79"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  local parsed="TITLE: Benign finding
SOURCE: Seer
LOCATION: src/a.ts:1
DETAILS: Detail one.
---ISSUE---
TITLE: Auth finding
SOURCE: code-reviewer
LOCATION: src/auth/jwt.ts:2
DETAILS: Detail two."

  create_batched_nonblocking_issue "${parsed}" "${PENDING_ISSUES_DIR}"

  grep -q "security" "${GH_CALLS_FILE}"
}

@test "create_batched_nonblocking_issue: writes a fallback file when gh fails" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="80"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/org/repo") echo "true"; exit 0 ;;
esac
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  create_batched_nonblocking_issue "TITLE: Lost finding
SOURCE: Seer
LOCATION: src/a.ts:1
DETAILS: Detail one." "${PENDING_ISSUES_DIR}"

  # The finding must survive somewhere on disk rather than being dropped.
  grep -rq "Lost finding" "${PENDING_ISSUES_DIR}"
}

@test "create_batched_nonblocking_issue: no gh issue create when there are no findings" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="81"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"
  : >"${GH_CALLS_FILE}"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  create_batched_nonblocking_issue "" "${PENDING_ISSUES_DIR}"

  ! grep -q "issue create" "${GH_CALLS_FILE}"
}

@test "create_batched_nonblocking_issue: consecutive checklist items do not run together" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="82"
  PR_TITLE="Batched PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  create_batched_nonblocking_issue "TITLE: First
SOURCE: Seer
LOCATION: src/a.ts:1
DETAILS: Detail one ends here.
---ISSUE---
TITLE: Second
SOURCE: Seer
LOCATION: src/b.ts:2
DETAILS: Detail two." "${PENDING_ISSUES_DIR}"

  # A detail line must never be immediately followed by the next bullet.
  ! grep -q 'Detail one ends here\.- \[ \]' "${GH_CALLS_FILE}"
}

@test "create_batched_nonblocking_issue: non-PR context does not emit 'PR #unknown' (#388)" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  # run-review.sh's whole-codebase review calls this with no PR in context.
  PR_NUMBER=""
  PR_TITLE=""
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  create_batched_nonblocking_issue "TITLE: Some finding
SOURCE: pre-push whole-codebase review
LOCATION: src/a.ts:1
DETAILS: Detail one." "${PENDING_ISSUES_DIR}"

  ! grep -q "PR #unknown" "${GH_CALLS_FILE}"
  ! grep -q "unknown" "${GH_CALLS_FILE}"
}

@test "create_batched_nonblocking_issue: PR context still names the PR in the title" {
  _load_fn _parse_issue_fields
  _load_fn _asserts_incorrectness
  _load_fn _format_issue_section
  _load_fn needs_security_label
  _load_fn is_security_critical
  _load_fn _repo_has_issues_enabled
  _load_fn _write_pending_issue_file
  _load_fn create_batched_nonblocking_issue

  PR_NUMBER="91"
  PR_TITLE="Some PR"
  REPO_OWNER="org"
  REPO_NAME="repo"
  GH_CALLS_FILE="${MOCK_DIR}/gh_calls"
  PENDING_ISSUES_DIR="${MOCK_DIR}/pending"

  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALLS_FILE}"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  create_batched_nonblocking_issue "TITLE: Some finding
SOURCE: code-reviewer
LOCATION: src/a.ts:1
DETAILS: Detail one." "${PENDING_ISSUES_DIR}"

  grep -q "from PR #91" "${GH_CALLS_FILE}"
}

@test "_dedup_location_path: strips a line number followed by a parenthetical (#387)" {
  _load_fn _dedup_location_path

  # #376/#377 were the same defect filed twice: dedup compares paths before
  # titles, and this form failed to parse down to a bare path, so the two
  # findings were never compared.
  run _dedup_location_path "scripts/hook-block-git-worktree.sh:114 (path_in_scope)"
  [[ "${output}" == "scripts/hook-block-git-worktree.sh" ]]
}

@test "_dedup_location_path: existing forms still parse correctly (#387)" {
  _load_fn _dedup_location_path

  run _dedup_location_path "scripts/a.sh:302"
  [[ "${output}" == "scripts/a.sh" ]]

  run _dedup_location_path "scripts/a.sh:10-20"
  [[ "${output}" == "scripts/a.sh" ]]

  run _dedup_location_path "scripts/a.sh"
  [[ "${output}" == "scripts/a.sh" ]]

  run _dedup_location_path "scripts/a.sh:10-20 (some_fn)"
  [[ "${output}" == "scripts/a.sh" ]]
}
