#!/usr/bin/env bash
# Tests for the primary-checkout branch guard in hook-block-main-commit.sh (#792).
# Every repo is a throwaway under one mktemp -d.

set -euo pipefail
unset CDPATH

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPTS}/hook-block-main-commit.sh"
WT_HOOK="${SCRIPTS}/hook-block-git-worktree.sh"
pass=0
fail=0

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
unset GIT_DIR GIT_WORK_TREE

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/branch-guard-test.XXXXXX")"
# Keep any log a hook writes inside the temp dir, not the real ~/.claude.
export HOME="${ROOT}/home"
mkdir -p "${HOME}/.claude"

# Protocol 3: rm is injectable, and it only ever removes this suite's own mktemp dir.
RM_BIN="${RM_BIN:-rm}"
cleanup() {
  [[ "${ROOT}" == */branch-guard-test.?????? && -d "${ROOT}" ]] || return 0
  "${RM_BIN}" -rf "${ROOT}"
}
trap cleanup EXIT

_init_repo() {
  local dir="${1}" branch="${2}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" checkout -q -b "${branch}"
  git -C "${dir}" config user.email test@test.com
  git -C "${dir}" config user.name Test
  printf 'a\n' >"${dir}/a.txt"
  git -C "${dir}" add a.txt
  git -C "${dir}" commit -q -m init
}

# PRIMARY: on main, origin/HEAD -> origin/main, local `feature`, and remote-only (DWIM would create it).
PRIMARY="${ROOT}/primary"
_init_repo "${PRIMARY}" main
git -C "${PRIMARY}" branch feature
git -C "${PRIMARY}" update-ref refs/remotes/origin/main HEAD
git -C "${PRIMARY}" update-ref refs/remotes/origin/remote-only HEAD
git -C "${PRIMARY}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
SHA="$(git -C "${PRIMARY}" rev-parse HEAD)"

# LINKED: a linked worktree of PRIMARY. Commands here are never guarded.
LINKED="${ROOT}/linked"
git -C "${PRIMARY}" worktree add -q "${LINKED}" -b wt-branch

# TRUNK: origin/HEAD names trunk and a local main exists, so origin/HEAD must win over the fallback.
TRUNK="${ROOT}/trunk"
_init_repo "${TRUNK}" trunk
git -C "${TRUNK}" branch main
git -C "${TRUNK}" update-ref refs/remotes/origin/trunk HEAD
git -C "${TRUNK}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk

# NOHEAD: on master with no origin/HEAD, so the fallback decides.
NOHEAD="${ROOT}/nohead"
_init_repo "${NOHEAD}" master
git -C "${NOHEAD}" branch other

# NONREPO: not a git repo at all.
NONREPO="${ROOT}/nonrepo"
mkdir -p "${NONREPO}"

make_input() {
  jq -n --arg cmd "$1" --arg cwd "$2" '{"tool_input":{"command":$cmd},"cwd":$cwd}'
}

# check <desc> <exit> <input cwd> <command>. The hook runs from NONREPO, so the repo must come from cwd or -C.
check() {
  local desc="${1}" expected="${2}" cwd="${3}" cmd="${4}" actual=0
  make_input "${cmd}" "${cwd}" | (cd "${NONREPO}" && "${HOOK}") >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

echo "=== hook-block-main-commit branch guard tests (#792) ==="

echo "--- denied in a primary checkout ---"
check "git checkout <branch>" 2 "${PRIMARY}" 'git checkout feature'
check "git checkout -b" 2 "${PRIMARY}" 'git checkout -b claude/new'
check "git checkout -B" 2 "${PRIMARY}" 'git checkout -B claude/new'
check "git checkout -b with start point" 2 "${PRIMARY}" 'git checkout -b claude/new origin/main'
check "git checkout --orphan" 2 "${PRIMARY}" 'git checkout --orphan fresh'
check "git checkout --detach" 2 "${PRIMARY}" 'git checkout --detach'
check "git checkout <sha> (detached)" 2 "${PRIMARY}" "git checkout ${SHA}"
check "git checkout origin/main (detached)" 2 "${PRIMARY}" 'git checkout origin/main'
check "git checkout <remote-only> (DWIM creates it)" 2 "${PRIMARY}" 'git checkout remote-only'
check "git checkout - (previous branch is not the default)" 2 "${PRIMARY}" 'git checkout -'
check "git checkout @{-1}" 2 "${PRIMARY}" 'git checkout @{-1}'
check "git checkout HEAD@{1}" 2 "${PRIMARY}" 'git checkout HEAD@{1}'
check "git switch -cNAME (attached value)" 2 "${PRIMARY}" 'git switch -cclaude/new'
check "git switch <branch>" 2 "${PRIMARY}" 'git switch feature'
check "git switch -c" 2 "${PRIMARY}" 'git switch -c claude/new'
check "git switch -C" 2 "${PRIMARY}" 'git switch -C claude/new'
check "git switch --create=" 2 "${PRIMARY}" 'git switch --create=claude/new'
check "git switch --detach" 2 "${PRIMARY}" 'git switch --detach origin/main'
check "git switch --orphan" 2 "${PRIMARY}" 'git switch --orphan fresh'
check "git stash branch" 2 "${PRIMARY}" 'git stash branch claude/new'
check "gh pr checkout" 2 "${PRIMARY}" 'gh pr checkout 5'
check "gh -R owner/name pr checkout" 2 "${PRIMARY}" 'gh -R owner/name pr checkout 5'
check "quoted branch name" 2 "${PRIMARY}" 'git switch "feature"'

echo "--- denied: wrappers, options and compound commands ---"
check "after another command (&&)" 2 "${PRIMARY}" 'git status && git switch feature'
check "after a newline" 2 "${PRIMARY}" "git status
git switch feature"
check "in a subshell" 2 "${PRIMARY}" '(git switch feature)'
check "in a brace group" 2 "${PRIMARY}" '{ git switch feature; }'
check "after then" 2 "${PRIMARY}" 'if true; then git switch feature; fi'
check "env wrapper with an assignment" 2 "${PRIMARY}" 'env FOO=1 git checkout feature'
check "leading assignment" 2 "${PRIMARY}" 'FOO=1 git checkout feature'
check "command wrapper" 2 "${PRIMARY}" 'command git switch feature'
check "path-qualified git" 2 "${PRIMARY}" '/usr/bin/git switch feature'
check "quoted git word" 2 "${PRIMARY}" '"git" switch feature'
check "quoted global option value" 2 "${PRIMARY}" 'git -c "user.name=A B" switch feature'
check "--no-pager before the subcommand" 2 "${PRIMARY}" 'git --no-pager checkout feature'
check "-C names the primary, cwd is the linked worktree" 2 "${LINKED}" "git -C ${PRIMARY} switch feature"
check "-C names the primary, cwd is not a repo" 2 "${NONREPO}" "git -C '${PRIMARY}' checkout -b claude/new"
check "relative -C resolves against the cwd" 2 "${ROOT}" 'git -C primary switch feature'

echo "--- denied: the repo cannot be resolved (fail closed) ---"
check "-C from a variable" 2 "${LINKED}" "git -C \"\${D}\" checkout -b claude/new"
check "-C from command substitution" 2 "${LINKED}" "git -C \$(pwd) switch feature"
check "an earlier cd" 2 "${LINKED}" "cd ${PRIMARY} && git switch feature"
check "an earlier cd, even into a linked worktree" 2 "${PRIMARY}" "cd ${LINKED} && git switch feature"
check "--git-dir hides the repo" 2 "${LINKED}" "git --git-dir=${PRIMARY}/.git switch feature"
check "unjoined line continuation" 2 "${PRIMARY}" 'git switch \
feature'

echo "--- allowed in a primary checkout ---"
check "git switch to the default branch" 0 "${PRIMARY}" 'git switch main'
check "git checkout the default branch" 0 "${PRIMARY}" 'git checkout main'
check "git -C <primary> switch main (post-merge cleanup)" 0 "${NONREPO}" "git -C ${PRIMARY} switch main"
check "git checkout -- <path>" 0 "${PRIMARY}" 'git checkout -- a.txt'
check "git checkout <ref> -- <path>" 0 "${PRIMARY}" 'git checkout feature -- a.txt'
check "git checkout HEAD -- <path>" 0 "${PRIMARY}" 'git checkout HEAD -- a.txt'
check "git checkout ." 0 "${PRIMARY}" 'git checkout .'
check "git checkout -- ." 0 "${PRIMARY}" 'git checkout -- .'
check "git checkout <file> (not a ref)" 0 "${PRIMARY}" 'git checkout a.txt'
check "git checkout -p" 0 "${PRIMARY}" 'git checkout -p'
check "bare git checkout (no-op)" 0 "${PRIMARY}" 'git checkout'
check "git pull" 0 "${PRIMARY}" 'git pull'
check "git worktree add (the replacement)" 0 "${PRIMARY}" 'git worktree add --no-track -b claude/new .claude/worktrees/x origin/main'
check "git restore" 0 "${PRIMARY}" 'git restore a.txt'
check "git branch (creates, does not move HEAD)" 0 "${PRIMARY}" 'git branch claude/new'
check "git checkout-index is not checkout" 0 "${PRIMARY}" 'git checkout-index -a'
check "git checkout HEAD (no move)" 0 "${PRIMARY}" 'git checkout HEAD'
check "an option value of gh does not read as gh pr checkout" 0 "${PRIMARY}" 'git -c user.name=gh switch main'
check "an option value of switch does not make checkout a switch" 0 "${PRIMARY}" 'git -c user.name=switch checkout a.txt'

echo "--- allowed: the phrase is text, not a command ---"
check "printf mentioning git checkout -b" 0 "${PRIMARY}" "printf '%s\\n' 'run git checkout -b x first'"
check "echo mentioning git switch" 0 "${PRIMARY}" 'echo "then git switch feature"'
check "commit message mentioning git checkout -b" 0 "${PRIMARY}" "git -C ${LINKED} commit -m \"docs: never git checkout -b x\""
check "commit message with ; before the phrase" 0 "${PRIMARY}" "git -C ${LINKED} commit -m \"fix; git checkout -b x\""
check "PR body mentioning gh pr checkout" 0 "${PRIMARY}" 'gh pr create --title t --body "do not; gh pr checkout 5"'
check "heredoc body mentioning git switch" 0 "${PRIMARY}" "cat <<'EOF' >notes.txt
git switch feature
git checkout -b x
EOF"
check "multi-line quoted string" 0 "${PRIMARY}" "printf '%s' 'line one
git switch feature'"
check "comment" 0 "${PRIMARY}" 'git status # then git switch feature'
check "grep for the phrase" 0 "${PRIMARY}" 'grep -rn "git checkout -b" docs/'

echo "--- allowed in a linked worktree ---"
check "git checkout <branch>" 0 "${LINKED}" 'git checkout feature'
check "git checkout -b" 0 "${LINKED}" 'git checkout -b claude/other'
check "git checkout --detach" 0 "${LINKED}" 'git checkout --detach'
check "git switch <branch>" 0 "${LINKED}" 'git switch feature'
check "git switch -c" 0 "${LINKED}" 'git switch -c claude/other'
check "gh pr checkout" 0 "${LINKED}" 'gh pr checkout 5'
check "-C names the linked worktree, cwd is the primary" 0 "${PRIMARY}" "git -C ${LINKED} switch -c claude/other"

echo "--- default branch from origin/HEAD, with a main/master fallback ---"
check "origin/HEAD=trunk: switch trunk allowed" 0 "${TRUNK}" 'git switch trunk'
check "origin/HEAD=trunk: switch main denied" 2 "${TRUNK}" 'git switch main'
check "no origin/HEAD, on master: switch master allowed" 0 "${NOHEAD}" 'git switch master'
check "no origin/HEAD, on master: switch other denied" 2 "${NOHEAD}" 'git switch other'

echo "--- not a git repo: nothing to guard ---"
check "git switch outside any repo" 0 "${NONREPO}" 'git switch feature'
check "gh pr checkout outside any repo" 0 "${NONREPO}" 'gh pr checkout 5'

echo "--- the deny message's replacement passes the worktree hook ---"
suggested=''
suggested="$(make_input 'git switch -c claude/new' "${PRIMARY}" | (cd "${NONREPO}" && "${HOOK}") 2>&1 >/dev/null |
  grep -E 'worktree add' | head -1 | sed -E 's/^[[:space:]]+//')" || true
if [[ "${suggested}" == *'git -C '*' worktree add --no-track '*' .claude/worktrees/'* ]]; then
  echo "  PASS: deny message names a --no-track worktree add under .claude/worktrees/"
  ((pass += 1))
else
  echo "  FAIL: deny message has no --no-track worktree add line (got: ${suggested})"
  ((fail += 1))
fi
# Fill the placeholder the way an agent would, then run it past the worktree hook.
concrete="${suggested//<name>/feat-x}"
concrete="${concrete//<branch>/claude/feat-x}"
actual=0
jq -n --arg cmd "${concrete}" '{"tool_input":{"command":$cmd}}' | "${WT_HOOK}" >/dev/null 2>&1 || actual=$?
if [[ "${actual}" -eq 0 ]]; then
  echo "  PASS: the suggested command passes hook-block-git-worktree.sh (${concrete})"
  ((pass += 1))
else
  echo "  FAIL: hook-block-git-worktree.sh blocks the suggested command (${concrete}, exit ${actual})"
  ((fail += 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
