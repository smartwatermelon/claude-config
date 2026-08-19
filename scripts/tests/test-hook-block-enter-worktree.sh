#!/usr/bin/env bash
# Tests for hook-block-enter-worktree.sh
#
# Policy under test (smartwatermelon/dotfiles#200): EnterWorktree is permitted,
# because worktree creation is permitted. The tool's tool_input carries only a
# `name` and no path, so there is nothing to path-scope; what is validated is
# that the name is a plain slug, since it becomes a directory component.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-enter-worktree.sh"
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
  jq -n --arg name "$1" '{"tool_input":{"name":$name}}'
}

echo "=== hook-block-enter-worktree tests ==="

# Should PASS (exit 0) — valid slugs
inp="$(make_input 'my-worktree')"
check "simple hyphenated slug" 0 "${inp}"
inp="$(make_input 'fix-gh-wrapper-issue-parsing')"
check "realistic branch-style slug" 0 "${inp}"
inp="$(make_input 'agent-a091b53da3a954c2e')"
check "agent-id style slug" 0 "${inp}"
inp="$(make_input 'wt_1.2')"
check "underscore and dot" 0 "${inp}"
inp="$(make_input 'a')"
check "single character" 0 "${inp}"

# Should BLOCK (exit 2) — names that would escape or confuse the worktree dir
inp="$(make_input '..')"
check "traversal: bare .." 2 "${inp}"
inp="$(make_input '../escape')"
check "traversal: ../escape" 2 "${inp}"
inp="$(make_input 'foo/../../etc')"
check "traversal: embedded .." 2 "${inp}"
inp="$(make_input 'nested/path')"
check "slash: nested path component" 2 "${inp}"
inp="$(make_input '/absolute')"
check "slash: absolute path" 2 "${inp}"
inp="$(make_input '.hidden')"
check "leading dot (hidden dir)" 2 "${inp}"
inp="$(make_input '-flaglike')"
check "leading hyphen (flag-like)" 2 "${inp}"
inp="$(make_input 'name with spaces')"
check "spaces" 2 "${inp}"

# The literal dollar/backtick are assembled rather than written inline so the
# hook receives genuinely unexpanded shell constructs.
dollar='$'
backtick='`'
inp="$(make_input "${dollar}(whoami)")"
check "command substitution" 2 "${inp}"
inp="$(make_input "${dollar}HOME")"
check "variable reference" 2 "${inp}"
inp="$(make_input "${backtick}id${backtick}")"
check "backtick substitution" 2 "${inp}"
inp="$(make_input 'semi;colon')"
check "shell operator" 2 "${inp}"
inp="$(make_input 'glob*')"
check "glob character" 2 "${inp}"

# Missing name: the harness would pick a default we cannot inspect.
inp='{"tool_input":{}}'
check "missing name" 2 "${inp}"
inp="$(make_input '')"
check "empty name" 2 "${inp}"

# Length bound (1-100 chars).
long_name="$(printf 'a%.0s' {1..100})"
inp="$(make_input "${long_name}")"
check "name at 100-char limit" 0 "${inp}"
too_long="$(printf 'a%.0s' {1..101})"
inp="$(make_input "${too_long}")"
check "name over 100-char limit" 2 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
