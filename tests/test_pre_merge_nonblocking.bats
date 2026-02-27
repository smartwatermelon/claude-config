#!/usr/bin/env bats
# Tests for non-blocking issue parsing and creation in pre-merge-review.sh
#
# Run: bats ~/.claude/tests/test_pre_merge_nonblocking.bats

bats_require_minimum_version 1.5.0

SCRIPT="${HOME}/.claude/hooks/pre-merge-review.sh"

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
export GH_CALLS_FILE="" PENDING_ISSUES_DIR=""

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
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
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
  _load_fn parse_nonblocking_issues
  _load_fn build_issue_body
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

NON_BLOCKING_ISSUE:
TITLE: Auth concern
SOURCE: Seer
LOCATION: src/auth/session.ts:99
DETAILS: Minor auth issue.
END_ISSUE"

  create_nonblocking_issues "${analysis}"

  grep -q "security" "${GH_CALLS_FILE}"
}
