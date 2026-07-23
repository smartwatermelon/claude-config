#!/usr/bin/env bats
# Tests for non-blocking issue parsing and creation in lib-review-issues.sh
#
# Run: bats ~/.claude/tests/test_pre_merge_nonblocking.bats

bats_require_minimum_version 1.5.0

SCRIPT="${HOME}/.claude/hooks/lib-review-issues.sh"

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
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block

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
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block

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
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block

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
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block

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
  _load_fn create_nonblocking_issues
  _load_fn _process_issue_block

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
