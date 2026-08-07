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

# Should BLOCK (exit 2) — mutating subcommands, bare worktree, unknown subcommands
inp="$(make_input 'git worktree add /tmp/wt feature')"
check "git worktree add" 2 "${inp}"
inp="$(make_input 'git worktree remove /tmp/wt')"
check "git worktree remove" 2 "${inp}"
inp="$(make_input 'git worktree prune')"
check "git worktree prune" 2 "${inp}"
inp="$(make_input 'git worktree move /tmp/wt /tmp/wt2')"
check "git worktree move" 2 "${inp}"
inp="$(make_input 'git worktree lock /tmp/wt')"
check "git worktree lock" 2 "${inp}"
inp="$(make_input 'git worktree unlock /tmp/wt')"
check "git worktree unlock" 2 "${inp}"
inp="$(make_input 'git worktree repair')"
check "git worktree repair" 2 "${inp}"
inp="$(make_input 'git worktree')"
check "bare git worktree (no subcommand)" 2 "${inp}"
inp="$(make_input 'git worktree unknownfuturesubcommand')"
check "git worktree unknown subcommand (fail closed)" 2 "${inp}"
inp="$(make_input 'git -C /some/path worktree add /tmp/wt')"
check "git -C /path worktree add" 2 "${inp}"
inp="$(make_input 'git --no-pager worktree add /tmp/wt')"
check "git --no-pager worktree add" 2 "${inp}"
inp="$(make_input 'cd /repo && git worktree add /tmp/wt')"
check "chained: cd && git worktree add" 2 "${inp}"

# Should PASS (exit 0) — read-only/inspection subcommands
inp="$(make_input 'git worktree list')"
check "git worktree list" 0 "${inp}"
inp="$(make_input 'git worktree --help')"
check "git worktree --help" 0 "${inp}"
inp="$(make_input 'git worktree -h')"
check "git worktree -h" 0 "${inp}"
inp="$(make_input 'git -C /some/path worktree list')"
check "git -C /path worktree list (interposed flag)" 0 "${inp}"
inp="$(make_input 'cd /repo && git worktree list')"
check "chained: cd && git worktree list" 0 "${inp}"
inp="$(make_input 'git commit -m msg')"
check "git commit" 0 "${inp}"
inp="$(make_input 'git checkout -b worktree-fix')"
check "git checkout -b worktree-fix" 0 "${inp}"
inp="$(make_input 'echo git worktree is blocked')"
check "echo about worktree" 0 "${inp}"
inp="$(make_input 'brew update')"
check "unrelated command" 0 "${inp}"

# Additional operator-chaining cases (read-only allowed through even when chained)
inp="$(make_input 'ls; git worktree list')"
check "chained: ; git worktree list" 0 "${inp}"
inp="$(make_input 'true || git worktree list')"
check "chained: || git worktree list" 0 "${inp}"
inp="$(make_input 'echo x | git worktree list')"
check "chained: | git worktree list" 0 "${inp}"

# Additional operator-chaining BLOCK cases (mutating still blocked when chained)
inp="$(make_input 'ls; git worktree add /tmp/wt')"
check "chained: ; git worktree add" 2 "${inp}"
inp="$(make_input 'true || git worktree prune')"
check "chained: || git worktree prune" 2 "${inp}"
inp="$(make_input 'echo x | git worktree add')"
check "chained: | git worktree add" 2 "${inp}"

# False-positive guard: git grep searching for "worktree" string
inp="$(make_input 'git grep worktree')"
check "git grep worktree (not blocked)" 0 "${inp}"

# Multi-invocation compound commands: a read-only occurrence must not mask a
# mutating one elsewhere in the same command string (regression for the
# single-match bypass caught in PR review — see smartwatermelon/claude-config#268).
inp="$(make_input 'git worktree list && git worktree add /tmp/wt')"
check "compound: list && add (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list | git worktree add /tmp/wt')"
check "compound: list | add (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree add /tmp/wt && git worktree list')"
check "compound: add && list, mutating first (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list ; git worktree remove /tmp/wt')"
check "compound: list ; remove (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list && git worktree --help')"
check "compound: list && --help, both read-only (must pass)" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
