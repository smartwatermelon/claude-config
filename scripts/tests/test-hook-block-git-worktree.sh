#!/usr/bin/env bash
# Tests for hook-block-git-worktree.sh

set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-git-worktree.sh"
pass=0
fail=0

check() {
  local desc="${1}" expected="${2}" input="${3}" actual
  actual=0
  printf '%s\n' "${input}" | "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

make_input() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

echo "=== hook-block-git-worktree tests ==="

# Should BLOCK (exit 2)
inp="$(make_input 'git worktree add /tmp/wt feature')"
check "git worktree add" 2 "${inp}"
inp="$(make_input 'git worktree list')"
check "git worktree list" 2 "${inp}"
inp="$(make_input 'git worktree remove /tmp/wt')"
check "git worktree remove" 2 "${inp}"
inp="$(make_input 'git worktree prune')"
check "git worktree prune" 2 "${inp}"
inp="$(make_input 'git -C /some/path worktree add /tmp/wt')"
check "git -C /path worktree add" 2 "${inp}"
inp="$(make_input 'git --no-pager worktree list')"
check "git --no-pager worktree list" 2 "${inp}"
inp="$(make_input 'cd /repo && git worktree add /tmp/wt')"
check "chained: cd && git worktree" 2 "${inp}"

# Should PASS (exit 0)
inp="$(make_input 'git commit -m msg')"
check "git commit" 0 "${inp}"
inp="$(make_input 'git checkout -b worktree-fix')"
check "git checkout -b worktree-fix" 0 "${inp}"
inp="$(make_input 'echo git worktree is blocked')"
check "echo about worktree" 0 "${inp}"
inp="$(make_input 'brew update')"
check "unrelated command" 0 "${inp}"

# Additional operator-chaining BLOCK cases
inp="$(make_input 'ls; git worktree list')"
check "chained: ; git worktree" 2 "${inp}"
inp="$(make_input 'true || git worktree list')"
check "chained: || git worktree" 2 "${inp}"
inp="$(make_input 'echo x | git worktree add')"
check "chained: | git worktree" 2 "${inp}"

# False-positive guard: git grep searching for "worktree" string
inp="$(make_input 'git grep worktree')"
check "git grep worktree (not blocked)" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
