#!/usr/bin/env bash
# Tests for hook-block-enter-worktree.sh
#
# Policy (2026-10-27): every EnterWorktree call is denied with the raw
# git command.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-enter-worktree.sh"
pass=0
fail=0

# check <desc> <expected-exit> <input> [stderr-ERE]
# Asserts the exit code and, when given, that stderr matches the ERE.
check() {
  local desc="${1}" expected="${2}" input="${3}" want_re="${4:-}" actual=0 err
  err="$(printf '%s\n' "${input}" | HOME="${fakehome}" "${HOOK}" 2>&1 >/dev/null)" || actual=$?
  if [[ "${actual}" -ne "${expected}" ]]; then
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  elif [[ -n "${want_re}" ]] && ! grep -qE -- "${want_re}" <<<"${err}"; then
    echo "  FAIL: ${desc} (stderr does not match: ${want_re})"
    printf '        %s\n' "${err}" | head -6
    ((fail += 1))
  else
    echo "  PASS: ${desc}"
    ((pass += 1))
  fi
}

# check_not <desc> <input> <stderr-ERE>: stderr must NOT match.
check_not() {
  local desc="${1}" input="${2}" bad_re="${3}" err
  err="$(printf '%s\n' "${input}" | HOME="${fakehome}" "${HOOK}" 2>&1 >/dev/null)" || true
  if grep -qE -- "${bad_re}" <<<"${err}"; then
    echo "  FAIL: ${desc} (stderr matches: ${bad_re})"
    ((fail += 1))
  else
    echo "  PASS: ${desc}"
    ((pass += 1))
  fi
}

# Fixtures live under a private temp dir and are left in place: the
# destructive-code rule bars a raw delete, and $TMPDIR is OS-cleaned.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/enter-wt-test.XXXXXX")"
fakehome="${fixture}/home"
mkdir -p "${fakehome}/.claude"
repo="${fixture}/repo"
notrepo="${fixture}/notrepo"
mkdir -p "${repo}" "${notrepo}"
# core.hooksPath=/dev/null keeps global git hooks out of this fixture repo.
git -C "${repo}" -c core.hooksPath=/dev/null init -q --template= -b fixture
git -C "${repo}" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid \
  commit -q --allow-empty -m init
git -C "${repo}" -c core.hooksPath=/dev/null worktree add -q --no-track -b claude/test-linked \
  "${repo}/.claude/worktrees/linked" HEAD

make_input() {
  jq -n --arg cwd "$1" --argjson ti "$2" '{"cwd":$cwd,"tool_name":"EnterWorktree","tool_input":$ti}'
}

RAW_TAIL='worktree add --no-track -b claude/<type>-<desc>-<session-id> \.claude/worktrees/'

echo "=== hook-block-enter-worktree tests ==="

# --- name form: denied, with the filled-in raw command ---
inp="$(make_input "${repo}" '{"name":"fix-thing"}')"
check "name: denied" 2 "${inp}" 'EnterWorktree is not used here'
check "name: raw add command names the repo and the name" 2 "${inp}" \
  "git -C /[^ ]*/repo ${RAW_TAIL}fix-thing origin/main"
check "name: verify command names the worktree path" 2 "${inp}" \
  'git -C /[^ ]*/repo/\.claude/worktrees/fix-thing rev-parse --show-toplevel'
check "name: says to work with absolute paths" 2 "${inp}" 'work with absolute paths'

# cwd inside a linked worktree still names the PRIMARY checkout.
inp="$(make_input "${repo}/.claude/worktrees/linked" '{"name":"wt2"}')"
check "name: cwd in a linked worktree resolves to the primary checkout" 2 "${inp}" \
  "git -C /[^ ]*/repo ${RAW_TAIL}wt2 origin/main"

# A name that is not a plain slug is never echoed into the command.
inp="$(make_input "${repo}" '{"name":"../escape;evil"}')"
check "name: non-slug name becomes the <name> placeholder" 2 "${inp}" \
  "${RAW_TAIL}<name> origin/main"
check_not "name: non-slug name is not echoed" "${inp}" 'escape'

# No name at all: placeholder.
inp="$(make_input "${repo}" '{}')"
check "missing name: denied with the <name> placeholder" 2 "${inp}" \
  "git -C /[^ ]*/repo ${RAW_TAIL}<name> origin/main"

# --- cwd not a repo / missing: still denied, with the <repo> placeholder ---
inp="$(make_input "${notrepo}" '{"name":"fix-thing"}')"
check "cwd not a repo: denied with the <repo> placeholder" 2 "${inp}" \
  "git -C <repo> ${RAW_TAIL}fix-thing origin/main"
inp="$(jq -n '{"tool_input":{"name":"fix-thing"}}')"
check "no cwd: denied with the <repo> placeholder" 2 "${inp}" \
  "git -C <repo> ${RAW_TAIL}fix-thing origin/main"
inp="$(make_input "${fixture}/does-not-exist" '{"name":"fix-thing"}')"
check "cwd does not exist: denied with the <repo> placeholder" 2 "${inp}" \
  "git -C <repo> ${RAW_TAIL}"

# --- path form: denied with the "already exists" message ---
wt_path="${repo}/.claude/worktrees/linked"
path_ti="$(jq -n --arg p "${wt_path}" '{"path":$p}')"
inp="$(make_input "${repo}" "${path_ti}")"
check "path: denied" 2 "${inp}" 'EnterWorktree is not used here'
check "path: says the worktree already exists" 2 "${inp}" 'already exists'
check "path: says no tool is needed" 2 "${inp}" 'no tool is needed'
check_not "path: does not suggest a new worktree add" "${inp}" 'worktree add'

# --- fail closed ---
# Malformed input must exit 2, not 1, which Claude Code treats as a
# non-blocking hook error (#796).
check "malformed JSON input: denied (exit 2)" 2 'not json {' 'could not be parsed'
check "empty input: denied (exit 2)" 2 ''

# An unwritable log must not change the verdict.
inp="$(make_input "${repo}" '{"name":"fix-thing"}')"
nohome="$(mktemp -d "${TMPDIR:-/tmp}/enter-wt-nohome.XXXXXX")"
actual=0
printf '%s\n' "${inp}" | HOME="${nohome}" "${HOOK}" >/dev/null 2>&1 || actual=$?
if [[ "${actual}" -eq 2 ]]; then
  echo "  PASS: unwritable log: still denied (exit 2)"
  ((pass += 1))
else
  echo "  FAIL: unwritable log: exit ${actual}, want 2"
  ((fail += 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
