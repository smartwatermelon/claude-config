#!/usr/bin/env bash
# Tests for hook-block-api-merge.sh

set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-api-merge.sh"
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

echo "=== hook-block-api-merge tests ==="

# REST API merge bypass — should BLOCK (exit 2)
inp="$(make_input 'gh api repos/owner/repo/pulls/123/merge --method PUT')"
check "REST: gh api .../pulls/N/merge --method PUT" 2 "${inp}"
inp="$(make_input 'gh api /repos/owner/repo/pulls/123/merge')"
check "REST: gh api /repos/.../merge (leading slash)" 2 "${inp}"
inp="$(make_input 'echo x && gh api repos/o/r/pulls/1/merge')"
check "REST: chained && gh api .../merge" 2 "${inp}"

# GraphQL mergePullRequest inline — should BLOCK (exit 2)
inp="$(make_input 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"PR_abc\"}) { pullRequest { id } } }"')"
check "GraphQL: inline mergePullRequest mutation" 2 "${inp}"

# GraphQL --input bypass — should BLOCK (exit 2)
inp="$(make_input 'gh api graphql --input /tmp/mutation.json')"
check "GraphQL: --input <file>" 2 "${inp}"
inp="$(make_input 'gh api graphql --input=/tmp/mutation.json')"
check "GraphQL: --input=<file> (equals form)" 2 "${inp}"
inp="$(make_input 'gh api graphql --input -')"
check "GraphQL: --input - (stdin)" 2 "${inp}"
inp="$(make_input 'gh api graphql -F input=@mutation.json')"
check "GraphQL: -F input=@file (equivalent form)" 2 "${inp}"
inp="$(make_input 'gh api graphql --field input=@mutation.json')"
check "GraphQL: --field input=@file (long form of -F)" 2 "${inp}"
inp="$(make_input 'gh api graphql --field=input=@mutation.json')"
check "GraphQL: --field=input=@file (equals long form)" 2 "${inp}"
inp="$(make_input 'cat mutation.json | gh api graphql --input -')"
check "GraphQL: piped to --input -" 2 "${inp}"

# Global-flag bypass — should BLOCK (exit 2)
inp="$(make_input 'gh -R owner/repo pr merge 123')"
check "Global flag: gh -R owner/repo pr merge" 2 "${inp}"
inp="$(make_input 'gh --repo owner/repo pr merge 123 --squash')"
check "Global flag: gh --repo owner/repo pr merge" 2 "${inp}"

# Legitimate uses — should PASS (exit 0)
inp="$(make_input 'gh api repos/owner/repo/pulls/123')"
check "REST: gh api .../pulls/N (no /merge)" 0 "${inp}"
inp="$(make_input 'gh api repos/owner/repo/pulls/123/comments')"
check "REST: gh api .../pulls/N/comments" 0 "${inp}"
inp="$(make_input 'gh api graphql -f query="query { viewer { login } }"')"
check "GraphQL: inline query (no mergePullRequest, no --input)" 0 "${inp}"
inp="$(make_input 'gh pr merge 123 --squash --delete-branch')"
check "Legit: gh pr merge (no global flags, routes through wrapper)" 0 "${inp}"
inp="$(make_input 'gh pr list')"
check "Legit: gh pr list" 0 "${inp}"
inp="$(make_input 'gh api user')"
check "Legit: gh api user" 0 "${inp}"

# git commit/log/show/diff exemption: literal patterns in commit messages or
# diff/log text must NOT trigger the block. The hook can't distinguish "command
# text" from "quoted argument text", so these verbs are early-exempted.
inp="$(make_input 'git commit -m "explain gh api graphql --input block"')"
check "Exempt: git commit -m with trigger text" 0 "${inp}"
inp="$(make_input 'git commit -m "describes gh api .../pulls/1/merge pattern"')"
check "Exempt: git commit -m with REST merge text" 0 "${inp}"
inp="$(make_input 'git log --oneline -5')"
check "Exempt: git log" 0 "${inp}"
inp="$(make_input 'git show HEAD')"
check "Exempt: git show" 0 "${inp}"
inp="$(make_input 'git diff main...HEAD')"
check "Exempt: git diff" 0 "${inp}"

# Negative: chained git diff && gh api ... must still block gh, since the
# exemption only applies when git is the leading verb.
inp="$(make_input 'git diff && gh api repos/o/r/pulls/1/merge')"
check "Not exempt: chained git diff && gh api merge" 2 "${inp}"

# Negative: command substitution $(gh ...) or `gh ...` inside a git commit -m
# still invokes gh at runtime — exemption must NOT fire.
inp="$(make_input 'git commit -m "$(gh api repos/o/r/pulls/1/merge --method PUT)"')"
check "Not exempt: git commit -m \"\$(gh api .../merge)\"" 2 "${inp}"
inp="$(make_input 'git commit -m "`gh api repos/o/r/pulls/1/merge`"')"
check "Not exempt: git commit -m \"\`gh api .../merge\`\"" 2 "${inp}"

# Negative: --input anchor boundary — must not false-match future --input-format
# style flags that happen to start with --input.
inp="$(make_input 'gh api graphql --input-format json -f query=q')"
check "Not blocked: --input-format (hypothetical future flag)" 0 "${inp}"

# Exempt: interposed git flags (-C, -c, --no-pager, etc.) before the verb.
# These forms are normal git usage and must still be exempted when the
# message text happens to contain a trigger pattern.
inp="$(make_input 'git -C /path commit -m "mentions gh api graphql --input"')"
check "Exempt: git -C /path commit -m with trigger text" 0 "${inp}"
inp="$(make_input 'git -c user.name=x commit -m "mentions gh api graphql --input"')"
check "Exempt: git -c key=value commit -m" 0 "${inp}"
inp="$(make_input 'git --no-pager log -5')"
check "Exempt: git --no-pager log" 0 "${inp}"
inp="$(make_input 'git -C /repo --no-pager show HEAD')"
check "Exempt: git -C /repo --no-pager show" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
