#!/usr/bin/env bash
# Tests for hook-block-pr-approve.sh

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-pr-approve.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# The hook appends each block to ${HOME}/.claude/blocked-commands.log; keep that out of the real home.
export HOME="${TMP}/home"
mkdir -p "${HOME}/.claude"
pass=0
fail=0

check() {
  local desc="${1}" expected="${2}" cmd="${3}" actual
  actual=0
  jq -n --arg cmd "${cmd}" '{"tool_input":{"command":$cmd}}' | "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

EP="repos/o/r/pulls/1/reviews"

echo "=== hook-block-pr-approve tests ==="

# Reads of the reviews endpoint — should PASS (exit 0)
check "read: plain GET with --jq" 0 "gh api ${EP} --jq '.[]|.state'"
check "read: explicit -X GET" 0 "gh api -X GET ${EP}"
check "read: jq filter on the APPROVED state" 0 "gh api ${EP} --jq '.[]|select(.state==\"APPROVED\")'"
check "read: chained with gh pr view --json" 0 "gh api ${EP} --jq '.[]|.state'; gh pr view 1 --repo o/r --json title,state,url"
check "read: --json= form in the chain" 0 "gh api ${EP}; gh pr view 1 --repo o/r --json=body,files"
check "read: two adjacent --json flags" 0 "gh api ${EP}; gh pr view 1 --json body --json files"
check "read: reviewDecision filter on APPROVED" 0 "gh api ${EP}; gh pr view 1 --json reviewDecision --jq 'select(.reviewDecision==\"APPROVED\")'"
check "unrelated: no reviews endpoint" 0 "gh pr view 1 --repo o/r --json title"

# Approvals — should BLOCK (exit 2)
check "gh pr review --approve" 2 "gh pr review 1 --approve"
check "gh pr review -a" 2 "gh pr review 1 -a"
check "REST: -f event=APPROVE" 2 "gh api ${EP} -f event=APPROVE"
check "REST: lowercase event=approve" 2 "gh api ${EP} -f event=approve"
check "REST: --field event=APPROVE" 2 "gh api ${EP} --field event=APPROVE"
check "REST: submit events endpoint with APPROVE" 2 "gh api ${EP}/7/events -f event=APPROVE"
check "REST: event=APPROVED still blocked as a write" 2 "gh api ${EP} -f event=APPROVED"
check "REST: APPROVED filter does not hide a write" 2 "gh api ${EP} -X POST -f body=x --jq 'select(.state==\"APPROVED\")'"

# Writes whose event the hook cannot see — should BLOCK (exit 2)
check "REST: -X POST -f body" 2 "gh api ${EP} -X POST -f body=x"
check "REST: -F event from file" 2 "gh api ${EP} -F event=@/tmp/ev"
check "REST: write alongside a gh --json read" 2 "gh api ${EP} -f body=x; gh pr view 1 --json title"
check "curl: --json inline body" 2 "curl -X POST https://api.github.com/${EP} --json '{\"body\":\"x\"}'"
check "curl: --json @file" 2 "curl https://api.github.com/${EP} --json @/tmp/body.json"
check "curl: --json empty object" 2 "curl https://api.github.com/${EP} --json '{}'"
check "curl: --json bare word that looks like a field list" 2 "curl https://api.github.com/${EP} --json body"
check "curl: --json bare word after a gh read" 2 "gh pr view 1 --json title; curl https://api.github.com/${EP} --json body"

# GraphQL — should BLOCK (exit 2)
check "GraphQL: addPullRequestReview" 2 "gh api graphql -f query='mutation { addPullRequestReview(input: {}) { clientMutationId } }'"
check "GraphQL: query from --input file" 2 "gh api graphql --input /tmp/q.json"

# Pending review create from a checked JSON file — PASS without an event, BLOCK with one
printf '{"body":"x","comments":[]}\n' >"${TMP}/pending.json"
check "pending: JSON file with no event" 0 "gh api ${EP} --input ${TMP}/pending.json"
printf '{"body":"x","event":"APPROVE"}\n' >"${TMP}/event.json"
check "pending: JSON file carrying an event" 2 "gh api ${EP} --input ${TMP}/event.json"
printf '{"body":"x","event":"APPROVED"}\n' >"${TMP}/approved.json"
check "pending: JSON file carrying event APPROVED" 2 "gh api ${EP} --input ${TMP}/approved.json"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
