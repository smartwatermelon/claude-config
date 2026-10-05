#!/usr/bin/env bash
# Tests that hook-block-no-verify.sh blocks pre-commit's SKIP= bypass (#650).
# Only the matcher runs; no listed command is ever executed.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-no-verify.sh"
pass=0
fail=0

# The hook appends to $HOME/.claude/blocked-commands.log; keep it scratch.
HOME="$(mktemp -d)"
export HOME
mkdir -p "${HOME}/.claude"
trap 'rm -rf "${HOME}"' EXIT

check() {
  local desc="${1}" expected="${2}" cmd="${3}" actual=0
  jq -n --arg cmd "${cmd}" '{"tool_input":{"command":$cmd}}' | "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

echo "=== hook-block-no-verify SKIP= tests ==="

echo "--- MUST BLOCK ---"
check "bare SKIP=x git commit" 2 'SKIP=x git commit -m t'
check "SKIP=a,b git commit" 2 'SKIP=a,b git commit -m t'
check "FOO=1 SKIP=x git commit" 2 'FOO=1 SKIP=x git commit -m t'
check "SKIP=x FOO=1 git commit" 2 'SKIP=x FOO=1 git commit -m t'
check "env SKIP=x git commit" 2 'env SKIP=x git commit -m t'
check "env FOO=1 SKIP=x git commit" 2 'env FOO=1 SKIP=x git commit -m t'
check "export SKIP=x && git commit" 2 'export SKIP=x && git commit -m t'
check "export SKIP=x; git commit" 2 'export SKIP=x; git commit -m t'
check "git -C dir commit with SKIP" 2 'SKIP=x git -C /some/dir commit -m t'
check "quoted SKIP value" 2 'SKIP="a,b" git commit -m t'
check "quoted other value before SKIP" 2 'FOO="a b" SKIP=x git commit -m t'
check "SKIP after && separator" 2 'git add f && SKIP=x git commit -m t'
check "SKIP with pre-commit run" 2 'SKIP=x pre-commit run --all-files'
check "env SKIP with pre-commit run" 2 'env SKIP=x pre-commit run'

echo "--- MUST NOT BLOCK ---"
check "plain git commit" 0 'git commit -m t'
check "FOO=1 git commit (no SKIP)" 0 'FOO=1 git commit -m t'
check "message containing SKIP=" 0 'git commit -m "docs: explain SKIP=length-caps"'
check "SKIP= with no commit on the line" 0 'SKIP=x echo hi'
check "SKIP-like variable name" 0 'MYSKIP=x git commit -m t'
check "pre-commit run without SKIP" 0 'pre-commit run --all-files'

echo
echo "Passed: ${pass}  Failed: ${fail}"
[[ "${fail}" -eq 0 ]]
