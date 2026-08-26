#!/usr/bin/env bash
# Tests that the short bypass-flag matcher only fires when the flag actually
# belongs to the git invocation (claude-config#405).
#
# The matcher used to be two independent greps ANDed over the whole command
# string: the flag anywhere, plus a git verb anywhere. That blocked commits
# whose MESSAGE discussed the flag while it was never passed to git.
#
# Loosening a security matcher needs the true positives pinned, or a fix for a
# false positive silently becomes a bypass. Both directions are asserted here.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-short-no-verify.sh"
pass=0
fail=0

# Assembled at runtime so this file's own invocation does not trip the hook it
# is testing.
readonly N="-""n"

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

echo "=== short bypass-flag scope tests ==="

# --- must BLOCK: the flag is an argument of the git command ---
check "flag after the verb" 2 "git commit ${N} -m x"
check "flag at end of the argument run" 2 "git commit -m x ${N}"
check "push" 2 "git push ${N} origin main"
check "chained after another command" 2 "echo hi && git commit ${N} -m x"
check "chained after a semicolon" 2 "cd /x ; git commit ${N} -m x"
check "push with an interposed flag" 2 "git push --tags ${N}"

# --- must ALLOW: the flag belongs to something else ---
check "unrelated tool flag" 0 "jq ${N} --arg a b '{}'"
check "grep flag, no git at all" 0 "grep ${N} pattern file"
check "plain commit, no flag" 0 "git commit -m x"

# --- #405: the false positive this suite exists for ---
# The flag appears in PROSE, and a git command appears separately. The old
# two-grep form blocked all three of these.
check "prose mentioning the flag, then an unrelated commit" \
  0 "echo \"the ${N} guard short-circuits\" && git commit -m x"
check "flag inside a message file, commit reads the file" \
  0 "printf \"uses ${N} here\" > /tmp/m && git commit -F /tmp/m"
check "another tool's flag, then an unrelated commit" \
  0 "grep ${N} 5 log.txt && git commit -m x"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
