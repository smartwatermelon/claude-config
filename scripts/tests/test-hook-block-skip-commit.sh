#!/usr/bin/env bash
# Tests that hook-block-no-verify.sh blocks pre-commit's SKIP= bypass (#650),
# except for allowlisted lint hooks (zizmor).
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
check "gate hook length-caps" 2 'SKIP=length-caps git commit -m t'
check "zizmor plus a gate" 2 'SKIP=zizmor,length-caps git commit -m t'
check "gate plus zizmor" 2 'SKIP=length-caps,zizmor git commit -m t'
check "zizmor then a gate on a second commit" 2 'SKIP=zizmor git commit -m a && SKIP=length-caps git commit -m b'
check "later SKIP= overrides zizmor" 2 'SKIP=zizmor SKIP=length-caps git commit -m t'
check "zizmor prefix match" 2 'SKIP=zizmorx git commit -m t'
dollar='$'
check "variable SKIP value" 2 "SKIP=${dollar}HOOKS git commit -m t"
check "command-substituted SKIP value" 2 "SKIP=\"${dollar}(echo zizmor)\" git commit -m t"
check "empty SKIP value" 2 'SKIP= git commit -m t'
check "quoted zizmor with a gate" 2 'SKIP="zizmor,length-caps" git commit -m t'
check "export zizmor, then a gate inline" 2 'export SKIP=zizmor && SKIP=length-caps git commit -m t'
check "gate hidden behind a quoted SKIP=zizmor" 2 'SKIP=length-caps,"SKIP=zizmor" git commit -m t'
check "lone ! SKIP= gate" 2 '! SKIP=length-caps git commit -m t'
check "gate after ! with zizmor first" 2 'SKIP=zizmor git commit -m a && ! SKIP=length-caps git commit -m b'
check "SKIP= in a message beside zizmor" 2 'SKIP=zizmor git commit -m "about SKIP=x"'

echo "--- MUST NOT BLOCK ---"
check "plain git commit" 0 'git commit -m t'
check "FOO=1 git commit (no SKIP)" 0 'FOO=1 git commit -m t'
check "message containing SKIP=" 0 'git commit -m "docs: explain SKIP=length-caps"'
check "SKIP= with no commit on the line" 0 'SKIP=x echo hi'
check "SKIP-like variable name" 0 'MYSKIP=x git commit -m t'
check "pre-commit run without SKIP" 0 'pre-commit run --all-files'
check "allowlisted SKIP=zizmor" 0 'SKIP=zizmor git commit -m t'
check "allowlisted, quoted" 0 'SKIP="zizmor" git commit -m t'
check "allowlisted, single-quoted" 0 "SKIP='zizmor' git commit -m t"
check "allowlisted with git -C" 0 'SKIP=zizmor git -C /some/dir commit -F /tmp/m'
check "allowlisted after env" 0 'env SKIP=zizmor git commit -m t'
check "allowlisted export then commit" 0 'export SKIP=zizmor && git commit -m t'
check "allowlisted on two commits" 0 'SKIP=zizmor git commit -m a && git add f && SKIP=zizmor git commit -m b'
check "later zizmor overrides a gate" 0 'SKIP=length-caps SKIP=zizmor git commit -m t'
check "trailing comma adds no hook" 0 'SKIP=zizmor, git commit -m t'
check "allowlisted after assignments and ;" 0 "W=/r; A=/a; SKIP=zizmor git -C \"${dollar}W\" commit -F \"${dollar}A/m\" && git -C \"${dollar}W\" add f && SKIP=zizmor git -C \"${dollar}W\" commit -F \"${dollar}A/n\""
check "allowlisted with pre-commit run" 0 'SKIP=zizmor pre-commit run --all-files'

echo
echo "Passed: ${pass}  Failed: ${fail}"
[[ "${fail}" -eq 0 ]]
