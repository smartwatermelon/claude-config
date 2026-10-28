#!/usr/bin/env bash
# hook-block-main-commit.sh: `W=/repo; git -C $W` and leading `cd /repo` resolve; the shared block matches personify's.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPTS}/hook-block-main-commit.sh"
pass=0
fail=0

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# Fixtures stay under one mktemp -d. Nothing here deletes anything.
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rr-main-commit.XXXXXX")"
ROOT="$(cd "${ROOT}" && pwd -P)"
export HOME="${ROOT}/home"
mkdir -p "${HOME}/.claude"

_init_repo() { # <dir> <branch>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" checkout -q -b "$2"
  git -C "$1" commit -q --allow-empty -m init
}
FEAT="${ROOT}/feat"
MAIN="${ROOT}/mainrepo"
_init_repo "${FEAT}" feature/work
_init_repo "${MAIN}" main
MSG="${ROOT}/scratchpad/commit-msg.txt"
mkdir -p "${ROOT}/scratchpad"
printf 'fix: a message\n' >"${MSG}"

# _check <label> <want-rc> <want-substring> <cwd> <command>; <cwd> is both the process and the JSON cwd.
_check() {
  local label="$1" want="$2" sub="$3" cwd="$4" c="$5" json err rc=0
  json="$(jq -n --arg c "${c}" --arg d "${cwd}" '{tool_input:{command:$c},cwd:$d}')"
  err="$(cd "${cwd}" && printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)" || rc=$?
  if [[ "${rc}" -eq "${want}" && "${err}" == *"${sub}"* ]]; then
    echo "  PASS: ${label}"
    pass=$((pass + 1))
  else
    echo "  FAIL: ${label} (want ${want}, got ${rc}): ${err}"
    fail=$((fail + 1))
  fi
}

echo "=== hook-block-main-commit: repo resolution ==="

echo "--- MUST NOT BLOCK: a literal assignment names a feature-branch repo (cwd on main) ---"
# Shapes from the denial inventory (2026-10), paths pointed at the fixtures.
_check "R=/abs; git -C \$R add ... && git -C \$R commit -F" 0 "" "${MAIN}" \
  "R=${FEAT}; git -C \$R add docs-tidy.py README.md && git -C \$R commit -F ${MSG} 2>&1 | tail -20"
_check "W=/abs; git -C \$W commit -F ... | grep | head; git -C \$W push" 0 "" "${MAIN}" \
  "W=${FEAT}; git -C \$W commit -F ${MSG} 2>&1 | grep -iE 'failed|blocked' | head; git -C \$W push -q origin HEAD"
_check "W=/abs; test \"\$(git -C \"\$W\" branch ...)\" = b && git -C \"\$W\" commit" 0 "" "${MAIN}" \
  "W=${FEAT}; test \"\$(git -C \"\$W\" branch --show-current)\" = feature/work && git -C \"\$W\" add a && git -C \"\$W\" commit -F ${MSG}"
_check "W=/abs; [[ ... ]] && git -c k=v -C \$W commit" 0 "" "${MAIN}" \
  "W=${FEAT}; [[ \"\$(git -C \$W branch --show-current)\" == feature/work ]] && git -c core.fsmonitor=false -C \$W commit -F ${MSG}"
_check "double-quoted value" 0 "" "${MAIN}" "W=\"${FEAT}\"; git -C \"\$W\" commit -m x"
_check "single-quoted value" 0 "" "${MAIN}" "W='${FEAT}' && git -C \"\$W\" commit -m x"
_check "\${W} form" 0 "" "${MAIN}" "W=${FEAT}; git -C \${W} commit -m x"
_check "\$S/sub suffix" 0 "" "${MAIN}" "S=${ROOT}; mkdir -p \$S; git -C \$S/feat commit -m x"
_check "two assignments, newline separated" 0 "" "${MAIN}" "S=${ROOT}/scratchpad
W=${FEAT}
git -C \$W commit -F \$S/commit-msg.txt"
# Unchanged: env -C with any $ value is denied by the #637 backstop, resolved or not.
_check "env -C \$W stays denied" 2 "env -C with a substituted directory" "${MAIN}" "W=${FEAT}; env -C \$W git commit -m x"

echo "--- MUST NOT BLOCK: a literal cd at the start (cwd on main) ---"
_check "cd /abs && W=\$PWD && git -C \"\$W\" commit" 0 "" "${MAIN}" \
  "cd ${FEAT} && W=\$PWD && git -C \"\$W\" add a && git -C \"\$W\" commit -F ${MSG}"
_check "cd /abs && git commit" 0 "" "${MAIN}" "cd ${FEAT} && git commit -F ${MSG}"
_check "cd \"/abs\"; git commit" 0 "" "${MAIN}" "cd \"${FEAT}\"; git commit -m x"

echo "--- MUST BLOCK: the resolved repo is on main (cwd on a feature branch) ---"
_check "W=<main repo>; git -C \$W commit" 2 "Cannot commit directly to main" "${FEAT}" \
  "W=${MAIN}; git -C \$W commit -m x"
_check "the last assignment wins" 2 "Cannot commit directly to main" "${FEAT}" \
  "W=${FEAT}; W=${MAIN}; git -C \$W commit -m x"
_check "cd <main repo> && git commit" 2 "Branch resolved from directory named by cd" "${FEAT}" \
  "cd ${MAIN} && git commit -m x"
_check "cd <main> && W=\$PWD && git -C \$W commit" 2 "Cannot commit directly to main" "${FEAT}" \
  "cd ${MAIN} && W=\$PWD && git -C \$W commit -m x"
_check "two cds: the last one counts" 2 "Cannot commit directly to main" "${FEAT}" \
  "cd ${FEAT} && cd ${MAIN} && git commit -m x"

echo "--- unchanged: a cd the scan does not follow keeps the cwd basis ---"
_check "cd to a missing dir: cwd (main) still judged" 2 "current directory" "${MAIN}" \
  "cd ${ROOT}/missing && git commit -m x"
_check "a later cd in a subshell: cwd (main) still judged" 2 "current directory" "${MAIN}" \
  "cd ${FEAT}; (cd ${MAIN}; true); git commit -m x"
_check "relative cd: cwd (main) still judged" 2 "current directory" "${MAIN}" \
  "cd feat && git commit -m x"

echo "--- MUST BLOCK: a variable the hook cannot resolve (cwd on a feature branch) ---"
_check "W=\$(pwd)" 2 "assigned from a command substitution" "${FEAT}" \
  "W=\$(pwd); git -C \$W commit -m x"
_check "tmp=\$(mktemp -d)" 2 "could not resolve \$tmp: assigned from a command substitution" "${FEAT}" \
  "tmp=\$(mktemp -d); git -C \$tmp init -q; git -C \$tmp commit -q --allow-empty -m i"
_check "never assigned" 2 "not assigned in this command" "${FEAT}" "git -C \"\$W\" commit -m x"
_check "assignment hidden in a quoted string" 2 "hides which repo" "${FEAT}" \
  "echo \"x; W=${FEAT}; \"; git -C \$W commit -m x"
_check "env-prefix assignment (not a statement)" 2 "hides which repo" "${FEAT}" \
  "W=${FEAT} git -C \$W commit -m x"
_check "assignment after another command" 2 "not as a literal absolute path" "${FEAT}" \
  "ls; W=${FEAT}; git -C \$W commit -m x"
_check "assignment in a subshell" 2 "hides which repo" "${FEAT}" \
  "(W=${FEAT}); git -C \$W commit -m x"
_check "reassigned later" 2 "names W again" "${FEAT}" \
  "W=${FEAT}; W=\$(pwd); git -C \$W commit -m x"
_check "read W later" 2 "names W again" "${FEAT}" \
  "W=${FEAT}; read -r W </dev/null; git -C \$W commit -m x"
_check "eval with a computed name later" 2 "builtin" "${FEAT}" \
  "W=${FEAT}; eval \"\$N=${MAIN}\"; git -C \$W commit -m x"
_check "value with .." 2 "hides which repo" "${FEAT}" \
  "W=${FEAT}/../mainrepo; git -C \$W commit -m x"
_check "value with a glob" 2 "hides which repo" "${FEAT}" \
  "W=${ROOT}/fea*; git -C \$W commit -m x"
_check "suffix with .." 2 "not a literal path" "${FEAT}" \
  "W=${FEAT}; git -C \$W/../mainrepo commit -m x"
_check "W=\$PWD with no cd before it" 2 "hides which repo" "${FEAT}" \
  "W=\$PWD; git -C \$W commit -m x"

echo "--- branch guard (#792) reads the resolved -C too ---"
_check "W=<primary checkout>; git -C \$W switch other: denied as a branch move" 2 "would move the primary checkout" "${FEAT}" \
  "W=${FEAT}; git -C \$W switch -c other"
_check "W=\$(pwd); git -C \$W switch: unknown" 2 "only known when the shell runs" "${FEAT}" \
  "W=\$(pwd); git -C \$W switch other"

echo "--- the repo-resolution block is the same in both hooks ---"
a="$(sed -n '/^# BEGIN repo-resolution/,/^# END repo-resolution/p' "${HOOK}")"
b="$(sed -n '/^# BEGIN repo-resolution/,/^# END repo-resolution/p' "${SCRIPTS}/hook-block-personify.sh")"
if [[ -n "${a}" && "${a}" == "${b}" ]]; then
  echo "  PASS: blocks match"
  pass=$((pass + 1))
else
  echo "  FAIL: the repo-resolution blocks differ, or one is missing"
  fail=$((fail + 1))
fi

echo ""
echo "Passed: ${pass}  Failed: ${fail}"
((fail == 0))
