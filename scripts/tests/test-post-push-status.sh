#!/usr/bin/env bash
set -euo pipefail

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
  if echo "${args}" | grep -q "pulls/99/comments"; then
    echo '[]'
    return 0
  fi
  echo "UNEXPECTED gh call: ${args}" >&2
  return 1
}
export -f gh

echo "=== Test: CI state from statusCheckRollup ==="
output=$(POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 42 2>/dev/null)
assert_contains "CI_STATE=FAILURE present" "CI_STATE=FAILURE" "${output}"

echo ""
echo "=== Test: Findings from bot accounts on current commit ==="
assert_contains "sentry[bot] finding included" "source=sentry[bot]" "${output}"
assert_contains "claude[bot] finding included" "source=claude[bot]" "${output}"
assert_not_contains "dependabot excluded" "source=dependabot[bot]" "${output}"
assert_not_contains "stale commit excluded" "oldsha" "${output}"

echo ""
echo "=== Test: Finding fields present ==="
assert_contains "file field present" "file=src/auth/token.ts" "${output}"
assert_contains "line field present" "line=47" "${output}"
assert_contains "comment text present" "null dereference" "${output}"

echo ""
echo "=== Test: POSTPUSH_OWNER/POSTPUSH_REPO override flows through to gh calls ==="
# Capture both stdout and stderr; the mock writes MOCK_CALLED_WITH=... to stderr
override_combined=$(POSTPUSH_OWNER=testowner POSTPUSH_REPO=testrepo \
  POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 99 2>&1)
assert_contains "gh called with testowner" "testowner" "${override_combined}"
assert_contains "gh called with testrepo" "testrepo" "${override_combined}"

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
