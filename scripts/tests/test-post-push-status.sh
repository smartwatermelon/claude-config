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

# assert_rc <label> <zero|nonzero> <exit code>
assert_rc() {
  local label="$1" want="$2" rc="$3" got="zero"
  if [[ "${rc}" -ne 0 ]]; then
    got="nonzero"
  fi
  if [[ "${got}" == "${want}" ]]; then
    echo "  PASS: ${label}"
    ((PASS += 1))
  else
    echo "  FAIL: ${label} (exit ${rc}, wanted ${want})"
    ((FAIL += 1))
  fi
}

gh() {
  local args="$*"
  # Log every call. The subject hides most gh stderr, so tests that
  # need the calls set MOCK_LOG.
  echo "MOCK_CALLED_WITH=${args}" >&2
  if [[ -n "${MOCK_LOG:-}" ]]; then
    printf '%s\n' "${args}" >>"${MOCK_LOG}"
  fi
  # Preflight pulls/<N>: REST body run through the real --jq.
  # 50 merged, 51 closed, 52 open at def456, others open at abc123.
  if echo "${args}" | grep -qE 'pulls/[0-9]+( |$)' \
    && ! echo "${args}" | grep -q "/comments" \
    && ! echo "${args}" | grep -q "statusCheckRollup"; then
    local _preflight_pr_num _body _pf_filter="" _pf_capture=0 _a
    _preflight_pr_num=$(echo "${args}" | grep -oE 'pulls/[0-9]+' | tail -1 | grep -oE '[0-9]+')
    case "${_preflight_pr_num}" in
      50) _body='{"number":50,"state":"closed","merged_at":"2025-12-15T00:00:00Z","head":{"sha":"abc123"}}' ;;
      51) _body='{"number":51,"state":"closed","merged_at":null,"head":{"sha":"abc123"}}' ;;
      52) _body='{"number":52,"state":"open","merged_at":null,"head":{"sha":"def456"}}' ;;
      *) _body="{\"number\":${_preflight_pr_num},\"state\":\"open\",\"merged_at\":null,\"head\":{\"sha\":\"abc123\"}}" ;;
    esac
    for _a in "$@"; do
      if [[ "${_pf_capture}" == "1" ]]; then
        _pf_filter="${_a}"
        break
      fi
      [[ "${_a}" == "--jq" ]] && _pf_capture=1
    done
    if [[ -n "${_pf_filter}" ]]; then
      printf '%s' "${_body}" | jq -r "${_pf_filter}"
    else
      printf '%s\n' "${_body}"
    fi
    return 0
  fi
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
  # GraphQL issues/comments fetch (replaces former REST issues/<N>/comments path).
  # Detect by the comments(last:...) selector inside a pullRequest(number:...) query.
  # The production code passes the PR number via `-F number=<N>`, so the args
  # string contains `number=<N>` reliably; route by that.
  #
  # The real `gh api graphql --jq <filter>` applies the filter to the response
  # before returning it. To exercise the production --jq projection (Bot →
  # `<login>[bot]` reconstruction, isMinimized filter), this mock returns the
  # raw GraphQL response and then pipes it through the actual `--jq` value
  # extracted from the call's args. That way the test verifies the real
  # production projection: minimized comments dropped, Bot authors reshaped.
  if echo "${args}" | grep -q "comments(last:" && echo "${args}" | grep -q "pullRequest(number:"; then
    local raw=""
    if echo "${args}" | grep -qF "number=42"; then
      raw='{"data":{"repository":{"pullRequest":{"comments":{"nodes":[
        {"body":"Critical: SQL injection vulnerability detected","createdAt":"2024-01-15T12:00:00Z","isMinimized":false,"author":{"__typename":"Bot","login":"sentry"}},
        {"body":"Stale finding from prior iteration","createdAt":"2024-01-14T08:00:00Z","isMinimized":false,"author":{"__typename":"Bot","login":"sentry"}},
        {"body":"<!-- claude-blocking-review --> VERDICT: PASS minimized","createdAt":"2024-01-15T13:00:00Z","isMinimized":true,"author":{"__typename":"Bot","login":"claude"}}
      ]}}}}}'
    elif echo "${args}" | grep -qF "number=99" && echo "${args}" | grep -qF "owner=testowner"; then
      raw='{"data":{"repository":{"pullRequest":{"comments":{"nodes":[]}}}}}'
    elif echo "${args}" | grep -qF "number=43"; then
      # PR 43: comment between PST-string and UTC commit time (timezone trap).
      raw='{"data":{"repository":{"pullRequest":{"comments":{"nodes":[
        {"body":"Stale PST-timezone trap comment","createdAt":"2026-03-13T01:00:00Z","isMinimized":false,"author":{"__typename":"Bot","login":"sentry"}}
      ]}}}}}'
    else
      echo "UNEXPECTED GraphQL comments call: ${args}" >&2
      return 1
    fi
    # Extract the --jq filter from the original argv (positional, not flatten)
    # so we apply the real production projection on the raw response.
    local jq_filter="" capture=0
    for a in "$@"; do
      if [[ "${capture}" == "1" ]]; then
        jq_filter="${a}"
        break
      fi
      if [[ "${a}" == "--jq" ]]; then
        capture=1
      fi
    done
    if [[ -n "${jq_filter}" ]]; then
      printf '%s' "${raw}" | jq -c "${jq_filter}"
    else
      printf '%s' "${raw}"
    fi
    return 0
  fi
  if echo "${args}" | grep -q "pulls/43/comments"; then
    echo '[]'
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
echo "=== Test: Minimized GraphQL comments are filtered out ==="
# PR 42 mock has a claude[bot] comment with isMinimized:true. The new
# _fetch_issue_comments_gql jq filter should drop it before the python parser
# sees it, so VERDICT: PASS body must NOT appear in output. (claude[bot]'s
# inline pulls/comment finding from PR 42 still appears — different code path,
# different content.)
assert_not_contains "minimized PASS comment dropped" "VERDICT: PASS" "${output}"

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

# --- #714: wrong-PR guards ---
# A bare N once polled another repo's merged PR and reported SUCCESS.

CWD_REPO=$(mktemp -d "${TMPDIR:-/tmp}/post-push-cwd.XXXXXX")
trap 'rm -rf "${CWD_REPO}"' EXIT
git -C "${CWD_REPO}" init -q
git -C "${CWD_REPO}" remote add origin git@github.com:cwdowner/cwdrepo.git

echo ""
echo "=== Test (#714): bare N resolves from the cwd and names the PR on stdout ==="
bare_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 42 2>/dev/null) || true)
assert_contains "RESOLVED_PR on stdout names cwd repo" "RESOLVED_PR=cwdowner/cwdrepo#42" "${bare_out}"
assert_contains "CI_STATE still reported" "CI_STATE=FAILURE" "${bare_out}"

echo ""
echo "=== Test (#714): OWNER/REPO#N overrides the cwd ==="
QUAL_LOG="${CWD_REPO}.gh-calls"
qual_out=$( (cd "${CWD_REPO}" && MOCK_LOG="${QUAL_LOG}" POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 'otherowner/otherrepo#42' 2>/dev/null) || true)
qual_calls=$(cat "${QUAL_LOG}" 2>/dev/null || echo "")
rm -f "${QUAL_LOG}"
assert_contains "RESOLVED_PR names the qualified repo" "RESOLVED_PR=otherowner/otherrepo#42" "${qual_out}"
assert_contains "gh preflight hit the qualified repo" "repos/otherowner/otherrepo/pulls/42" "${qual_calls}"
assert_contains "GraphQL rollup asked the qualified owner" "owner=otherowner" "${qual_calls}"
assert_not_contains "cwd repo never polled" "cwdowner" "${qual_calls}"
assert_contains "CI_STATE from the qualified repo" "CI_STATE=FAILURE" "${qual_out}"

echo ""
echo "=== Test (#714): a PR URL is accepted like OWNER/REPO#N ==="
url_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 'https://github.com/otherowner/otherrepo/pull/42' 2>/dev/null) || true)
assert_contains "URL resolves to owner/repo#N" "RESOLVED_PR=otherowner/otherrepo#42" "${url_out}"

echo ""
echo "=== Test (#714): a MERGED PR reports UNKNOWN, says why, exits nonzero ==="
merged_rc=0
merged_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 50 2>/dev/null)) || merged_rc=$?
assert_contains "merged PR -> CI_STATE=UNKNOWN" "CI_STATE=UNKNOWN" "${merged_out}"
assert_not_contains "merged PR rollup not reported" "CI_STATE=FAILURE" "${merged_out}"
assert_contains "reason on stdout" "PR_STATE=MERGED" "${merged_out}"
assert_rc "merged PR exits nonzero" nonzero "${merged_rc}"

echo ""
echo "=== Test (#714): a CLOSED PR reports UNKNOWN ==="
closed_rc=0
closed_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 51 2>/dev/null)) || closed_rc=$?
assert_contains "closed PR -> CI_STATE=UNKNOWN" "CI_STATE=UNKNOWN" "${closed_out}"
assert_contains "closed reason on stdout" "PR_STATE=CLOSED" "${closed_out}"
assert_rc "closed PR exits nonzero" nonzero "${closed_rc}"

echo ""
echo "=== Test (#714): headRefOid != local HEAD with a bare N -> UNKNOWN ==="
mm_rc=0
mm_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 52 2>/dev/null)) || mm_rc=$?
assert_contains "mismatch -> CI_STATE=UNKNOWN" "CI_STATE=UNKNOWN" "${mm_out}"
assert_not_contains "mismatch rollup not reported" "CI_STATE=FAILURE" "${mm_out}"
assert_contains "warning names the PR head" "def456" "${mm_out}"
assert_contains "warning names the local HEAD" "abc123" "${mm_out}"
assert_contains "warning names the local repo" "cwdowner/cwdrepo" "${mm_out}"
assert_rc "mismatch exits nonzero" nonzero "${mm_rc}"

echo ""
echo "=== Test (#714): headRefOid mismatch with explicit OWNER/REPO#N only warns ==="
mmq_rc=0
mmq_out=$( (cd "${CWD_REPO}" && POSTPUSH_CURRENT_COMMIT="abc123" bash "${SUBJECT}" 'otherowner/otherrepo#52' 2>/dev/null)) || mmq_rc=$?
assert_contains "explicit mismatch warns" "HEAD_MISMATCH" "${mmq_out}"
assert_contains "explicit mismatch still reports the rollup" "CI_STATE=FAILURE" "${mmq_out}"
assert_rc "explicit mismatch exits zero" zero "${mmq_rc}"

echo ""
echo "=== Test (#714): malformed PR arguments are rejected ==="
bad_rc=0
(cd "${CWD_REPO}" && bash "${SUBJECT}" 'not-a-number' >/dev/null 2>&1) || bad_rc=$?
assert_rc "non-numeric PR rejected" nonzero "${bad_rc}"
bad_rc=0
(cd "${CWD_REPO}" && bash "${SUBJECT}" '../evil#5' >/dev/null 2>&1) || bad_rc=$?
assert_rc "bad repo slug rejected" nonzero "${bad_rc}"

echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
[[ "${FAIL}" -eq 0 ]]
