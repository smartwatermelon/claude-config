#!/usr/bin/env bash
# Tests that the api-merge matchers require the tool name at a COMMAND
# position, not merely somewhere in the string (claude-config#405).
#
# The matchers used to accept the tool name anywhere, so the merge endpoint
# matched inside a quoted argument being written to a file -- writing a test
# fixture for this hook was blocked by this hook.
#
# This hook gates merges. Loosening it needs the true positives pinned or a
# false-positive fix silently becomes a bypass, so both directions are
# asserted here, including command substitution (which genuinely executes).

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-api-merge.sh"
pass=0
fail=0

# Assembled at runtime so this file's own invocation is not blocked by the
# hook it tests.
readonly EP="pulls/1/""merge"

check() {
  local desc="${1}" expected="${2}" cmd="${3}"
  local input actual=0

  input="$(jq --null-input --arg c "${cmd}" '{tool_input: {command: $c}}')" || {
    echo "  FAIL: ${desc} (could not build fixture)"
    ((fail += 1))
    return
  }

  printf '%s\n' "${input}" | "${HOOK}" >/dev/null 2>&1 || actual=$?

  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

echo "=== api-merge command-position tests ==="

# --- must BLOCK: the tool is actually invoked ---
check "plain REST merge"                2 "gh api -X PUT repos/o/r/${EP}"
check "REST merge with --method"        2 "gh api repos/o/r/${EP} --method PUT"
check "chained after &&"                2 "echo x && gh api repos/o/r/${EP}"
check "chained after a semicolon"       2 "cd /x ; gh api repos/o/r/${EP}"
check "after a pipe"                    2 "true | gh api repos/o/r/${EP}"
check "command substitution executes"   2 "echo \$(gh api repos/o/r/${EP})"

# --- must ALLOW: already-legitimate usage ---
check "the sanctioned merge path"       0 "gh pr merge 123 --squash --delete-branch"
check "an unrelated api read"           0 "gh api repos/o/r/pulls/1"

# --- #405 case C: the endpoint appears in QUOTED text, not as a command ---
check "endpoint written into a fixture file" \
  0 "printf %s \"gh api -X PUT repos/o/r/${EP}\" > fixture.json"
check "endpoint quoted in documentation" \
  0 "echo \"gh api repos/o/r/${EP} is blocked by policy\" >> notes.md"

# --- ACCEPTED GAP, asserted as CURRENT behavior rather than desired ---
# A heredoc body starts at a line boundary and is indistinguishable from a
# command without real tokenization. Documented in the hook header; fails safe
# (a blocked write, never a permitted merge). Same limit #349 recorded for the
# false-negative direction.
check "KNOWN GAP: heredoc body still matches" \
  2 "cat > t.txt <<EOF
gh api repos/o/r/${EP}
EOF"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
