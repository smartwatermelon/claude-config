#!/usr/bin/env bash
# hook-block-personify.sh: the hook resolves the real destination from the
# command (git -C, gh -R/--repo, gh api repos/o/n, else the hook's cwd) and
# passes it to `gate-review.sh check`, so the route follows where the text
# goes and not where it was staged.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
[[ -x "${HOOK}" ]] || {
  echo "cannot find hook at ${HOOK}" >&2
  exit 1
}
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

# Sandbox: no user git config, no repo discovery above the scratch tree, no
# real gate dir (so no SUSPENDED file), no real check records.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GH_WRAPPER_LIB="${GH_WRAPPER_LIB:-/Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh}"
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
# The three production rules, copied so a later edit to the real file cannot
# change what this test exercises.
export GATE_RULES_FILE="${TMP}/rules.conf"
cat >"${GATE_RULES_FILE}" <<'RULES'
repo=andrewmrich/beacon-workspace visual
author=andrewmrich pangram
* visual
RULES

pass=0
fail=0
_ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
_no() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
BEACON="${TMP}/beacon"
PERSONAL="${TMP}/personal"
WORKSPACE="${TMP}/workspace"
_mkrepo "${BEACON}" beacon-biosignals/x
_mkrepo "${PERSONAL}" twistedmelonman/y
_mkrepo "${WORKSPACE}" andrewmrich/beacon-workspace

TXT="${GATE_REVIEW_DIR}/approved/k1/msg"
printf 'fix(x): approved text\n' >"${TXT}"
SHA="$(sha256sum "${TXT}" | cut -d' ' -f1)"
REC="${XDG_CONFIG_HOME}/personify/checks/${SHA}.json"
_rec() { printf '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":120}\n' >"${REC}"; }
_norec() { rm -f "${REC}"; }

# _run <cwd> <command>: pipe hook JSON in; set rc and err.
_run() {
  local json
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
}
# _case <label> <want-rc> <want-substring> <cwd> <command>
_case() {
  local label="$1" wrc="$2" wsub="$3"
  _run "$4" "$5"
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}

_norec
_case "git -C pangram repo, no record: blocked" 2 "no Pangram check ran" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_rec
_case "git -C pangram repo, with record: passes" 0 "" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_norec
_case "git -C visual repo, no record: passes" 0 "" "${TMP}" \
  "git -C ${PERSONAL} commit -F ${TXT}"
_case "commit with no -C uses the hook cwd (pangram)" 2 "no Pangram check ran" "${BEACON}" \
  "git commit -F ${TXT}"
_case "commit with no -C uses the hook cwd (visual)" 0 "" "${PERSONAL}" \
  "git commit -F ${TXT}"
_case "relative -C resolves against the hook cwd" 2 "no Pangram check ran" "${TMP}" \
  "git -C beacon commit -F ${TXT}"
_case "commit -C <sha> is not a directory" 2 "no Pangram check ran" "${BEACON}" \
  "git commit -C abc123 -F ${TXT}"
_case "-C with a variable blocks" 2 "cannot resolve the repository" "${TMP}" \
  "git -C \$R commit -F ${TXT}"

_case "gh pr create -R pangram repo, no record: blocked" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R beacon-biosignals/x"
_case "gh --repo=... pangram repo: blocked" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} --repo=beacon-biosignals/x"
_case "gh pr create from the beacon-workspace checkout: passes, no record" 0 "" "${WORKSPACE}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh pr create from a personal checkout: passes, no record" 0 "" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh pr create from a beacon checkout: blocked, no record" 2 "no Pangram check ran" "${BEACON}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh api repos/o/n path names the destination" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh api repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT}"
_case "gh api without a repo path uses the hook cwd" 0 "" "${PERSONAL}" \
  "gh api user/foo -F body=@${TXT}"

# The trust test: a text staged and approved as visual in one repo must not
# publish to a pangram repo just because the bytes are approved.
_case "approved as visual, committed to a pangram repo: blocked" 2 "no Pangram check ran" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_rec
_case "same, once a record exists: passes" 0 "" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"

# Fix round 1: destinations the hook cannot resolve must not fall to the weaker
# rule. Each of these runs from a visual cwd with no record, so a silent
# fallthrough would pass (rc 0).
_norec
_case "gh -R with a variable blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R \$REPO"
_case "gh api repos/\$OWNER/\$NAME blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh api repos/\$OWNER/\$NAME/issues/1/comments -F body=@${TXT}"
_case "gh api repos/\$SLUG blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh api repos/\${SLUG}/issues/1/comments -F body=@${TXT}"

_case "cd <pangram repo> && git commit follows the cd" 2 "no Pangram check ran" "${PERSONAL}" \
  "cd ${BEACON} && git commit -F ${TXT}"
_case "cd <pangram repo> && gh pr create follows the cd" 2 "no Pangram check ran" "${PERSONAL}" \
  "cd ${BEACON} && gh pr create --title t --body-file ${TXT}"
_case "cd inside a subshell follows the cd" 2 "no Pangram check ran" "${PERSONAL}" \
  "(cd ${BEACON} && git commit -F ${TXT} )"
_case "relative cd resolves against the cwd" 2 "no Pangram check ran" "${TMP}" \
  "cd beacon && git commit -F ${TXT}"
_case "pushd follows the cd" 2 "no Pangram check ran" "${PERSONAL}" \
  "pushd ${BEACON} && git commit -F ${TXT}"
_case "last cd wins (back to a visual repo)" 0 "" "${BEACON}" \
  "cd ${BEACON} && cd ${PERSONAL} && git commit -F ${TXT}"
_case "cd to a visual repo from a pangram cwd passes" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && git commit -F ${TXT}"
_case "git -C after cd resolves against the cd target" 2 "no Pangram check ran" "${TMP}" \
  "cd ${TMP} && git -C beacon commit -F ${TXT}"
_case "cd with a variable target blocks" 2 "cannot resolve" "${PERSONAL}" \
  "cd \$DIR && git commit -F ${TXT}"
_case "bare cd blocks" 2 "cannot resolve" "${PERSONAL}" \
  "cd && git commit -F ${TXT}"
_case "cd - blocks" 2 "cannot resolve" "${PERSONAL}" \
  "cd - && gh pr create --title t --body-file ${TXT}"
_case "a cd with no gated segment after it is fine" 0 "" "${PERSONAL}" \
  "cd \$DIR && ls"

_case "--git-dir blocks" 2 "use git -C" "${PERSONAL}" \
  "git --git-dir=${BEACON}/.git commit -F ${TXT}"
_case "--git-dir separate arg blocks" 2 "use git -C" "${PERSONAL}" \
  "git --git-dir ${BEACON}/.git commit -F ${TXT}"
_case "--work-tree blocks" 2 "use git -C" "${PERSONAL}" \
  "git --work-tree=${BEACON} commit -F ${TXT}"
_case "GIT_DIR= prefix blocks" 2 "use git -C" "${PERSONAL}" \
  "GIT_DIR=${BEACON}/.git git commit -F ${TXT}"
_case "GIT_WORK_TREE= prefix blocks" 2 "use git -C" "${PERSONAL}" \
  "GIT_WORK_TREE=${BEACON} git commit -F ${TXT}"
_case "env GIT_DIR= prefix blocks" 2 "use git -C" "${PERSONAL}" \
  "env GIT_DIR=${BEACON}/.git git commit -F ${TXT}"

# Unchanged behaviour.
_norec
_case "inline -m still blocks" 2 "text given inline" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -m hello"
_case "relative message path still blocks" 2 "is not absolute" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -F msg.txt"
printf 'unapproved\n' >"${TMP}/other.txt"
_case "unapproved bytes still block" 2 "do not match anything approved" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -F ${TMP}/other.txt"

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
