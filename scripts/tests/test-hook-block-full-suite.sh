#!/usr/bin/env bash
# Tests for scripts/hook-block-full-suite.sh: full suites are blocked, scoped
# test files pass.
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-full-suite.sh"
HOME="$(mktemp -d)"
export HOME
mkdir -p "${HOME}/.claude"
fail=0

check() {
  local want="$1" cmd="$2" rc
  jq -n --arg c "${cmd}" '{tool_input: {command: $c}}' | bash "${HOOK}" >/dev/null 2>&1
  rc=$?
  if [[ "${rc}" == "${want}" ]]; then
    echo "PASS: rc=${rc} ${cmd}"
  else
    echo "FAIL: want rc=${want}, got ${rc}: ${cmd}"
    fail=1
  fi
}

check 2 'bash scripts/run-tests.sh'
check 2 'bash /Users/x/Developer/claude-config/.claude/worktrees/w/scripts/run-tests.sh > log 2>&1; echo rc=$?'
check 2 './run-tests.sh --fail-fast'
check 2 'cd bash/tests && run-tests.sh'
check 2 'bash scripts/site-monitor/tests/run-tests.sh'
check 2 'python3 -m unittest discover -s tests -v'
check 2 'python3 -m unittest'
check 2 'pytest'
check 2 'bats tests/'
check 2 'bats -r tests'
check 2 'npm test'
check 2 'pnpm run test'
check 2 'make test'
check 0 'CI=1 npx expo export'
check 2 'cd /x && bash scripts/run-tests.sh'
check 2 'bats tests/ ; bats x.bats'
check 2 'python3 -m pytest'
check 2 'pytest -q'
check 2 'python3 -m pytest -v -x'
check 2 'python3 -m unittest -v'
check 2 'timeout 900 bash scripts/run-tests.sh'
check 2 "bash -c 'scripts/run-tests.sh'"
check 2 'npm run test:unit'
check 2 'bats tests/*.bats'
check 0 'pytest -q tests/test_one.py'
check 0 'shellcheck -S info scripts/run-tests.sh'
check 0 'git add scripts/run-tests.sh'
check 0 'cat scripts/run-tests.sh'
check 0 'git -C /x commit -F /tmp/msg.txt'
check 0 'echo run the full suite: bash scripts/run-tests.sh is CI only'
check 0 'bash scripts/tests/test-gate-lint.sh'
check 0 'bats tests/test_run_tests.bats'
check 0 'python3 -m unittest tests.test_length_check'
check 0 'pytest tests/test_one.py'
check 0 'npm test -- foo.test.ts'
check 0 'git -C /x log --oneline'
check 0 'grep -n run-tests docs/notes.md'

exit "${fail}"
