#!/usr/bin/env bash
# Tests for hook-block-main-commit.sh
#
# Two defects motivated this suite (#429):
#
#   1. The matcher tested for ` commit ` as a whitespace-delimited token
#      ANYWHERE in a command starting with `git `, so read-only commands were
#      blocked as if they were commits: `git show HEAD # explains the commit`
#      and `git log --oneline -- commit` both exited 2.
#   2. The branch was resolved from the hook process's own working directory
#      whenever the command carried no `-C`, so the verdict could name a repo
#      the command never touches.
#
# The TRUE POSITIVE cases below are the load-bearing half. This hook is a
# safety control, and the failure mode of a too-loose matcher is a real commit
# reaching main. Every form that must keep blocking is pinned here, so a future
# narrowing of the pattern cannot quietly un-block one.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-main-commit.sh"
pass=0
fail=0

# The scratch repos must not inherit the user's global git config: an
# init.templateDir there installs the very pre-commit hooks under test, whose
# main-branch guard would block these fixtures' own setup commits. Point every
# git invocation in this suite at an empty global config instead.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

# A scratch repo checked out on main. The hook resolves the branch of whatever
# repo it runs in when the command carries no -C, so these tests run from here
# to exercise the on-main path.
REPO_MAIN="$(mktemp -d)"
git -C "${REPO_MAIN}" init -q
git -C "${REPO_MAIN}" checkout -q -b main
git -C "${REPO_MAIN}" config user.email test@test.com
git -C "${REPO_MAIN}" config user.name Test
git -C "${REPO_MAIN}" commit -q --allow-empty -m init

# A repo on main whose path contains spaces, so the quoted `-C` handling is
# exercised against a real repository rather than a nonexistent path. A path
# that does not resolve yields branch `unknown`, which never equals main --
# so a broken extraction would look like a pass here without this fixture.
REPO_SPACED="$(mktemp -d)/path with spaces"
mkdir -p "${REPO_SPACED}"
git -C "${REPO_SPACED}" init -q
git -C "${REPO_SPACED}" checkout -q -b main
git -C "${REPO_SPACED}" config user.email test@test.com
git -C "${REPO_SPACED}" config user.name Test
git -C "${REPO_SPACED}" commit -q --allow-empty -m "chore: init"

# A third scratch repo on `master`, since the hook guards both default-branch
# names and only `main` is exercised elsewhere in this suite.
REPO_MASTER="$(mktemp -d)"
git -C "${REPO_MASTER}" init -q
git -C "${REPO_MASTER}" checkout -q -b master
git -C "${REPO_MASTER}" config user.email test@test.com
git -C "${REPO_MASTER}" config user.name Test
git -C "${REPO_MASTER}" commit -q --allow-empty -m "chore: init"

# A second scratch repo on a feature branch, used to prove the hook reads the
# repo named by -C rather than the one it happens to be standing in.
REPO_FEATURE="$(mktemp -d)"
git -C "${REPO_FEATURE}" init -q
git -C "${REPO_FEATURE}" checkout -q -b feature/work
git -C "${REPO_FEATURE}" config user.email test@test.com
git -C "${REPO_FEATURE}" config user.name Test
git -C "${REPO_FEATURE}" commit -q --allow-empty -m init

cleanup() {
  rm -rf "${REPO_MAIN}" "${REPO_FEATURE}" "${REPO_MASTER}" "$(dirname "${REPO_SPACED}")"
}
trap cleanup EXIT

make_input() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

# Run the hook from ${cwd} with ${cmd}, assert the exit status.
check_from() {
  local desc="${1}" expected="${2}" cwd="${3}" cmd="${4}" actual
  actual=0
  make_input "${cmd}" | (cd "${cwd}" && "${HOOK}") >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

# Most cases run from the on-main repo; wrap for brevity.
check() {
  check_from "${1}" "${2}" "${REPO_MAIN}" "${3}"
}

echo "=== hook-block-main-commit tests ==="

echo "--- MUST BLOCK: real commit invocations while on main ---"
check "bare git commit" 2 'git commit'
check "git commit -m" 2 'git commit -m msg'
check "git commit --amend" 2 'git commit --amend'
check "git commit -a -m" 2 'git commit -a -m msg'
check "git commit -am (bundled flags)" 2 'git commit -am msg'
check "git commit -F file" 2 'git commit -F /tmp/msg'
check "git commit --no-verify" 2 'git commit --no-verify -m msg'
check "git commit with trailing args" 2 'git commit -m msg -- path/to/file'

echo "--- MUST BLOCK: commit reached past global flags and wrappers ---"
check "git --no-pager commit" 2 'git --no-pager commit -m msg'
check "git -c user.name=x commit" 2 'git -c user.name=x commit -m msg'
check "env-wrapped git commit" 2 'env FOO=1 git commit -m msg'
check "path-qualified git commit" 2 '/usr/bin/git commit -m msg'
check "commit after && separator" 2 'git add f && git commit -m msg'
check "commit after ; separator" 2 'git add f ; git commit -m msg'

echo "--- MUST BLOCK: master, not just main ---"
check_from "git commit while on master" 2 "${REPO_MASTER}" 'git commit -m msg'
check_from "git -C <master repo> commit" 2 "${REPO_FEATURE}" \
  "git -C ${REPO_MASTER} commit -m msg"

echo "--- MUST BLOCK: -C naming a repo that IS on main ---"
check_from "git -C <main repo> commit, run from feature repo" 2 \
  "${REPO_FEATURE}" "git -C ${REPO_MAIN} commit -m msg"
# The env-wrapper normalization rewrites the command before the match is taken,
# and -C is then read back out of that match. Pin the combination so a change
# to either step cannot silently drop the explicit repo and fall back to cwd.
check_from "env-wrapped git -C <main repo> commit" 2 \
  "${REPO_FEATURE}" "env FOO=1 git -C ${REPO_MAIN} commit -m msg"

echo "--- MUST BLOCK: several global options before the subcommand ---"
# The option arm repeats, and -C may sit anywhere among the flags. Both orders
# must reach `commit` AND still resolve the branch from the named repo rather
# than the cwd, so these run from the feature repo: a regression that lost the
# -C would resolve to feature/work and silently allow the commit.
check_from "-C before another global option" 2 \
  "${REPO_FEATURE}" "git -C ${REPO_MAIN} -c user.name=x commit -m msg"
check_from "-C after another global option" 2 \
  "${REPO_FEATURE}" "git -c user.name=x -C ${REPO_MAIN} commit -m msg"
check_from "-C after a valueless global option" 2 \
  "${REPO_FEATURE}" "git --no-pager -C ${REPO_MAIN} commit -m msg"

echo "--- MUST BLOCK: quoted values on global options ---"
# A quoted value may contain spaces, which the bare value-token arm stops at.
# Both halves matter: the matcher has to reach `commit` past the quoted value,
# and the -C extraction has to recover the whole quoted path. A path that fails
# to resolve yields branch `unknown`, which silently does NOT equal main -- so
# these run against REPO_SPACED, a real repo on main.
check "double-quoted -c value with a space" 2 'git -c "user.name=First Last" commit -m msg'
check "single-quoted -c value with a space" 2 "git -c 'user.name=First Last' commit -m msg"
check_from "double-quoted -C path with spaces" 2 \
  "${REPO_FEATURE}" "git -C \"${REPO_SPACED}\" commit -m msg"
check_from "single-quoted -C path with spaces" 2 \
  "${REPO_FEATURE}" "git -C '${REPO_SPACED}' commit -m msg"

echo "--- MUST NOT BLOCK: read-only commands containing the word 'commit' ---"
# The regression cases from #429. None of these commit anything.
#
# Each appears twice, with and without a trailing space. The trailing space is
# NOT load-bearing -- verified that both forms behave identically -- but the
# end-of-string form is the one a person actually types, and it exercises the
# `$` half of the trailing `([[:space:]]|$)` anchor rather than the
# `[[:space:]]` half. Keeping both means neither branch of that anchor can
# regress unnoticed.
check "git log with 'commit' as the last token" 0 'git log --oneline -- commit'
check "git show with 'commit' ending the comment" 0 'git show HEAD # explains the commit'
check "git show with 'commit' in a trailing comment" 0 'git show HEAD # explains the commit '
check "git log with 'commit' as a pathspec" 0 'git log --oneline -- commit '
check "git log --format with 'commit' pathspec" 0 'git log --format=%H -1 -- commit '
check "git log --grep for the word commit" 0 'git log --grep=fix -- commit '
check "git rev-list counting commits" 0 'git rev-list --count HEAD -- commit '
check "git cat-file on a commit object" 0 'git cat-file -t HEAD -- commit '

echo "--- MUST NOT BLOCK: a separator is never eaten as a flag value ---"
# The bare-token arm of _optval opens with [^-], which admits any non-dash
# character. The question is whether the engine can therefore consume a real
# shell separator as though it were a flag's value, running past a genuine
# command boundary and matching a later `commit` that belongs to a different
# command. It cannot -- the arm's body excludes | ; & and the backtick -- but
# that is a claim about runtime matching, so it is pinned rather than argued.
check "pipe after a flag, commit in the next command" 0 'git log -p | grep commit '
check "semicolon after a flag, commit in the next command" 0 'git log -p ; echo commit '
check "ampersand after a flag, commit in the next command" 0 'git log -p & echo commit '
# The mirror case: a REAL commit after a separator must still block, so the
# three above cannot be satisfied by simply failing to look past separators.
check "real commit after a pipeline and a semicolon" 2 'git log -p | true ; git commit -m x'

echo "--- MUST NOT BLOCK: ordinary read-only git commands ---"
check "git status" 0 'git status'
check "git rev-parse" 0 'git rev-parse HEAD'
check "git diff --cached" 0 'git diff --cached'
check "git branch --show-current" 0 'git branch --show-current'

echo "--- MUST NOT BLOCK: non-git commands mentioning commit ---"
check "gh issue create quoting a commit example" 0 \
  'gh issue create --title x --body "repro: run git commit -m test"'
check "echo mentioning commit" 0 'echo "remember to commit "'

echo "--- MUST BLOCK: further wrapper and quoting forms ---"
check "git commit --allow-empty" 2 'git commit --allow-empty'
check "commit after a cd" 2 'cd /somewhere && git commit -m x'
check "commit inside bash -c" 2 'bash -c "git commit -m x"'
check "git -C . commit" 2 'git -C . commit -m x'
check "git --git-dir= commit" 2 'git --git-dir=.git commit -m x'
check "command-wrapped git commit" 2 'command git commit -m x'
check "sudo-wrapped git commit" 2 'sudo git commit -m x'

echo "--- MUST NOT BLOCK: 'commit' inside a longer token ---"
# The subcommand must be exactly `commit`; these carry it as a prefix of a
# config key or an option value, not as the subcommand itself.
check "git config commit.gpgsign" 0 'git config commit.gpgsign false'
check "git log --author=committer" 0 'git log --author=committer'
check "non-git grep for commit" 0 'grep -r commit .'
# These two are what the trailing ([[:space:]]|$) anchor buys: both are
# subcommands whose names merely BEGIN with `commit`. Without the anchor the
# pattern matches the prefix and blocks them. `commit-tree` is plumbing that
# writes a commit object without moving any branch, so it is not the thing
# this hook exists to prevent.
check "git commit-tree (plumbing, moves no branch)" 0 'git commit-tree HEAD^{tree}'
check "a subcommand merely prefixed with commit" 0 'git commitmsg-helper'

echo "--- MUST NOT BLOCK: committing while NOT on main ---"
check_from "git commit from a feature branch" 0 "${REPO_FEATURE}" 'git commit -m msg'
check_from "git -C <feature repo> commit" 0 "${REPO_MAIN}" \
  "git -C ${REPO_FEATURE} commit -m msg"

echo
echo "Passed: ${pass}  Failed: ${fail}"
[[ "${fail}" -eq 0 ]]
