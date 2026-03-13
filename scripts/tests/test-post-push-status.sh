#!/usr/bin/env bash
set -euo pipefail

# Unset BASH_ENV so child bash processes do not re-source the global functions.sh,
# which would re-export the real gh() wrapper and override the test mock.
unset BASH_ENV
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="${SCRIPT_DIR}/../post-push-status.sh"

PASS=0
FAIL=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${label}"
    ((PASS += 1))
  else
    echo "  FAIL: ${label}"
    echo "        expected to find: ${needle}"
    echo "        in output:        ${haystack}"
    ((FAIL += 1))
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if ! echo "${haystack}" | grep -qF "${needle}"; then
    echo "  PASS: ${label}"
    ((PASS += 1))
  else
    echo "  FAIL: ${label}"
    echo "        expected NOT to find: ${needle}"
    echo "        in output:            ${haystack}"
    ((FAIL += 1))
  fi
}

gh() {
  local args="$*"
  # Log all calls so tests can assert on owner/repo values flowing through
  echo "MOCK_CALLED_WITH=${args}" >&2
  if echo "${args}" | grep -q "statusCheckRollup"; then
    # For PR 99 (owner/repo override test), require owner=testowner so wrong owner hits UNEXPECTED
    if echo "${args}" | grep -qF "number=99" && ! echo "${args}" | grep -qF "owner=testowner"; then
      echo "UNEXPECTED gh call (wrong owner for PR 99 GQL): ${args}" >&2
      return 1
    fi
    echo '{"data":{"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}}}}'
    return 0
  fi
  if echo "${args}" | grep -q "pulls/42/comments"; then
    cat <<'EOF'
[
  {"id":1,"user":{"login":"sentry[bot]"},"original_commit_id":"abc123","body":"Potential null dereference at line 47","path":"src/auth/token.ts","line":47},
  {"id":2,"user":{"login":"sentry[bot]"},"original_commit_id":"oldsha","body":"Old comment on stale commit","path":"src/foo.ts","line":10},
  {"id":3,"user":{"login":"dependabot[bot]"},"original_commit_id":"abc123","body":"Bump lodash","path":"package.json","line":1},
  {"id":4,"user":{"login":"claude[bot]"},"original_commit_id":"abc123","body":"Consider extracting this logic","path":"src/utils.ts","line":22}
]
EOF
    return 0
  fi
  if echo "${args}" | grep -qF "testowner/testrepo/pulls/99/comments"; then
    echo '[]'
    return 0
  fi
  if echo "${args}" | grep -q "issues/42/comments"; then
    cat <<'EOF'
[
  {"id":10,"user":{"login":"sentry[bot]"},"created_at":"2024-01-15T12:00:00Z","body":"Critical: SQL injection vulnerability detected","html_url":"https://github.com/..."},
  {"id":11,"user":{"login":"sentry[bot]"},"created_at":"2024-01-14T08:00:00Z","body":"Stale finding from prior iteration","html_url":"https://github.com/..."}
]
EOF
    return 0
  fi
  if echo "${args}" | grep -qF "testowner/testrepo/issues/99/comments"; then
    echo '[]'
    return 0
  fi
  if echo "${args}" | grep -q "pulls/43/comments"; then
    echo '[]'
    return 0
  fi
  # PR 43: issues/comments with a comment created between PST-string and UTC time of commit.
  # Commit at 2026-03-13T02:08:00Z (= 2026-03-12T18:08:00-08:00 PST).
  # Comment at 2026-03-13T01:00:00Z is 1 hour BEFORE commit in UTC (stale → should be filtered).
  # Old bug: "2026-03-13T01:00:00Z" > "2026-03-12T18:08:00-08:00" (string compare) → not filtered.
  # Fixed:   "2026-03-13T01:00:00Z" < "2026-03-13T02:08:00Z" (UTC vs UTC) → correctly filtered.
  if echo "${args}" | grep -q "issues/43/comments"; then
    cat <<'EOF'
[
  {"id":20,"user":{"login":"sentry[bot]"},"created_at":"2026-03-13T01:00:00Z","body":"Stale PST-timezone trap comment","html_url":"https://github.com/..."}
]
EOF
    return 0
  fi
  echo "UNEXPECTED gh call: ${args}" >&2
  return 1
}
export -f gh

echo "=== Test: CI state from statusCheckRollup ==="
# Commit timestamp set to 2024-01-15T10:00:00Z so:
#   - issues/comment id=10 (created_at 2024-01-15T12:00:00Z) is FRESH → included
#   - issues/comment id=11 (created_at 2024-01-14T08:00:00Z) is STALE → excluded
output=$(POSTPUSH_CURRENT_COMMIT="abc123" POSTPUSH_COMMIT_TIMESTAMP="2024-01-15T10:00:00Z" \
  bash "${SUBJECT}" 42 2>/dev/null)
assert_contains "CI_STATE=FAILURE present" "CI_STATE=FAILURE" "${output}"

echo ""
echo "=== Test: Findings from bot accounts on current commit ==="
assert_contains "sentry[bot] finding included" "source=sentry[bot]" "${output}"
assert_contains "claude[bot] finding included" "source=claude[bot]" "${output}"
assert_not_contains "dependabot excluded" "source=dependabot[bot]" "${output}"
assert_not_contains "stale commit excluded" "oldsha" "${output}"
assert_contains "issues/comments fresh sentry[bot] finding included" "SQL injection" "${output}"

echo ""
echo "=== Test: Timestamp filter excludes stale issues/comments ==="
assert_not_contains "stale issues/comment excluded" "Stale finding from prior iteration" "${output}"

echo ""
echo "=== Test: Finding fields present ==="
assert_contains "file field present" 'file="src/auth/token.ts"' "${output}"
assert_contains "line field present" "line=47" "${output}"
assert_contains "comment text present" "null dereference" "${output}"

echo ""
echo "=== Test: POSTPUSH_OWNER/POSTPUSH_REPO override flows through to gh calls ==="
# Run the subject with owner/repo overrides and PR 99 (no bot comments).
# The mock gh() only returns valid GQL JSON if testowner/testrepo are passed through
# correctly (any other owner/repo would hit the UNEXPECTED fallback and exit 1).
# CI_STATE=FAILURE in stdout proves the override values reached the gh api call.
override_combined=$(POSTPUSH_OWNER=testowner POSTPUSH_REPO=testrepo \
  POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 99 2>&1)
assert_contains "gh called with correct owner/repo (CI_STATE present)" "CI_STATE=" "${override_combined}"
assert_not_contains "unexpected gh call (override values not routed)" "UNEXPECTED gh call" "${override_combined}"
assert_contains "testowner in resolved owner" "RESOLVED_OWNER=testowner" "${override_combined}"
assert_contains "testrepo in resolved repo" "RESOLVED_REPO=testrepo" "${override_combined}"

echo ""
echo "=== Test: UTC timestamp normalization filters stale PST-timezone-trap comments ==="
# Scenario: commit at 2026-03-13T02:08:00Z (= 2026-03-12T18:08:00-08:00 in PST).
# A stale bot comment was posted at 2026-03-13T01:00:00Z (1hr before commit in UTC).
# Bug: %cI gave "2026-03-12T18:08:00-08:00"; string compare with "2026-03-13T01:00:00Z"
#      incorrectly found comment AFTER commit (Z > - in ASCII) → stale not filtered.
# Fix: TZ=UTC git show gives "2026-03-13T02:08:00Z"; string compare correctly finds
#      "2026-03-13T01:00:00Z" < "2026-03-13T02:08:00Z" → stale filtered.
pst_utc_output=$(POSTPUSH_CURRENT_COMMIT="abc123" \
  POSTPUSH_COMMIT_TIMESTAMP="2026-03-13T02:08:00Z" \
  bash "${SUBJECT}" 43 2>/dev/null)
assert_not_contains "PST-timezone-trap stale comment filtered" "Stale PST-timezone trap comment" "${pst_utc_output}"
assert_contains "CI_STATE present for PR 43" "CI_STATE=" "${pst_utc_output}"

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
