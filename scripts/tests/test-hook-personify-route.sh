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
# gate-review.sh hint reads installed_plugins.json from here; keep it off the
# real one.
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GH_WRAPPER_LIB="${GH_WRAPPER_LIB:-/Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh}"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
# The three production rules, copied so a later edit to the real file cannot
# change what this test exercises.
export GATE_RULES_FILE="${TMP}/rules.conf"
cat >"${GATE_RULES_FILE}" <<'RULES'
repo=andrewmrich/beacon-workspace visual
author=andrewmrich pangram
* visual
RULES
# A stub length_check.py that passes everything: CI has no personify checkout, and test-*-length.sh use the real one.
_stub_personify() { # <config dir> <install dir>
  mkdir -p "$1/plugins" "$2/scripts"
  : >"$2/scripts/pangram_check.py"
  printf 'import sys\nsys.exit(0)\n' >"$2/scripts/length_check.py"
  jq -n --arg p "$2" '{plugins:{"personify@personify":[{installPath:$p}]}}' >"$1/plugins/installed_plugins.json"
}
_stub_personify "${CLAUDE_CONFIG_DIR}" "${TMP}/personify"
STUB_PLUGINS="$(cat "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json")"

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
_case "cd inside a subshell denies (parentheses with a cd)" 2 "cd combined with parentheses" "${PERSONAL}" \
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

# Fix round 3: a cd combined with parentheses anywhere in the command denies
# every gated segment (a regex cannot count parens through quotes).
_case "cd in a closed subshell, then commit from a pangram cwd: blocked" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && true); git commit -F ${TXT}"
_case "cd in a closed subshell, then gh pr create: blocked" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && true); gh pr create --title t --body-file ${TXT}"
_case "quoted unbalanced ( inside the subshell cannot mask the close" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && echo \"(x\" && true); git commit -F ${TXT}"
_case "commit in the same group as its cd now denies" 2 "cd combined with parentheses" "${PERSONAL}" \
  "( cd ${BEACON} && git commit -F ${TXT} )"
_case "plain cd, no parentheses, still resolves to the target (pangram)" 2 "no Pangram check ran" "${PERSONAL}" \
  "cd ${BEACON} && git commit -F ${TXT}"
_case "plain cd, no parentheses, still resolves to the target (visual)" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && git commit -F ${TXT}"
_case "parentheses with no cd are unaffected" 0 "" "${PERSONAL}" \
  "(echo hi) && git commit -F ${TXT}"
_case "parentheses with no cd are unaffected (pangram still routes by cwd)" 2 "no Pangram check ran" "${BEACON}" \
  "(echo hi) && git commit -F ${TXT}"

# Final review C1: every gh destination form is read, and the ones the hook
# cannot read deny. Each runs with no record, so a fall to the visual cwd
# would pass (rc 0).
_norec
NOREPO="${TMP}/norepo"
mkdir -p "${NOREPO}"
URL="https://github.com/beacon-biosignals/x"
_case "gh pr comment <URL> from a personal cwd routes to the URL" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr comment ${URL}/pull/5 --body-file ${TXT}"
_case "gh pr comment <URL> from a non-repo cwd routes to the URL" 2 "no Pangram check ran" "${NOREPO}" \
  "gh pr comment ${URL}/pull/5 --body-file ${TXT}"
_case "gh issue comment <URL> routes to the URL" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh issue comment ${URL}/issues/5 --body-file ${TXT}"
_case "gh pr review <URL> --comment routes to the URL" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr review ${URL}/pull/5 --comment --body-file ${TXT}"
_case "gh pr edit <URL> routes to the URL" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr edit ${URL}/pull/5 --body-file ${TXT}"
_case "-R github.com/o/n is normalized" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R github.com/beacon-biosignals/x"
_case "-R https://github.com/o/n is normalized" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R ${URL}"
_case "-R with mixed case is normalized" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R Beacon-Biosignals/X"
_case "-R URL and a matching <URL> argument agree" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh pr comment ${URL}/pull/5 -R beacon-biosignals/x --body-file ${TXT}"
_case "attached -Ro/n denies" 2 "attached -R" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -Rbeacon-biosignals/x"
_case "attached -R=o/n denies" 2 "attached -R" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R=beacon-biosignals/x"
_case "-R on another host denies" 2 "single owner/name" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R ghe.example.com/beacon-biosignals/x"
_case "GH_REPO= prefix denies" 2 "GH_REPO" "${PERSONAL}" \
  "GH_REPO=beacon-biosignals/x gh pr create --title t --body-file ${TXT}"
_case "export GH_REPO then gh denies" 2 "GH_REPO" "${PERSONAL}" \
  "export GH_REPO=beacon-biosignals/x; gh pr create --title t --body-file ${TXT}"
_case "GH_REPO with gh api repos/{owner}/{repo} denies" 2 "GH_REPO" "${PERSONAL}" \
  "GH_REPO=beacon-biosignals/x gh api repos/{owner}/{repo}/issues/1/comments -F body=@${TXT}"
_case "title carrying -R cannot steer away from a pangram cwd" 2 "inside quoted text" "${BEACON}" \
  "gh pr create --title \"see -R twistedmelonman/y\" --body-file ${TXT}"
_case "title carrying -R cannot override a real -R" 2 "inside quoted text" "${PERSONAL}" \
  "gh pr create -R beacon-biosignals/x --title \"x -R twistedmelonman/y\" --body-file ${TXT}"
_case "title carrying a github.com URL denies" 2 "inside quoted text" "${BEACON}" \
  "gh pr create --title \"port of github.com/twistedmelonman/y\" --body-file ${TXT}"
_case "two -R that disagree deny" 2 "more than one repository" "${PERSONAL}" \
  "gh pr create -R beacon-biosignals/x -R twistedmelonman/y --title t --body-file ${TXT}"
_case "a <URL> and a -R that disagree deny" 2 "more than one repository" "${PERSONAL}" \
  "gh pr comment ${URL}/pull/5 -R twistedmelonman/y --body-file ${TXT}"
_case "an unquoted github.com value with no -R also checks the pangram cwd" 2 "no Pangram check ran" "${BEACON}" \
  "gh pr comment https://github.com/twistedmelonman/y/pull/5 --body-file ${TXT}"
_case "a personal <URL> from a personal cwd passes" 0 "" "${PERSONAL}" \
  "gh pr comment https://github.com/twistedmelonman/y/pull/5 --body-file ${TXT}"
_case "gh api repositories/<id> denies" 2 "by number" "${PERSONAL}" \
  "gh api repositories/12345/issues/1/comments -F body=@${TXT}"
_case "gh api repos/{owner}/{repo} uses the cwd (pangram)" 2 "no Pangram check ran" "${BEACON}" \
  "gh api repos/{owner}/{repo}/issues/1/comments -F body=@${TXT}"
_case "gh api repos/{owner}/{repo} uses the cwd (visual)" 0 "" "${PERSONAL}" \
  "gh api repos/{owner}/{repo}/issues/1/comments -F body=@${TXT}"
_case "gh api full api.github.com URL names the repo" 2 "no Pangram check ran" "${PERSONAL}" \
  "gh api https://api.github.com/repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT}"
_case "gh api repos/o/n with a field naming another repo denies" 2 "more than one repository" "${PERSONAL}" \
  "gh api repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT} -f ref=https://github.com/twistedmelonman/y"
RTXT="${TMP}/repos/twistedmelonman/y/msg"
mkdir -p "${RTXT%/*}"
cp "${TXT}" "${RTXT}"
_case "a /repos/o/n inside the body file path is not an endpoint" 2 "no Pangram check ran" "${BEACON}" \
  "gh api user/x -F body=@${RTXT}"
_case "repos/{owner}/{repo} plus a repos/ path in the body file still checks the cwd" 2 "no Pangram check ran" "${BEACON}" \
  "gh api repos/{owner}/{repo}/issues/1/comments -F body=@${RTXT}"

# Final review I1: a cd/pushd/popd the hook does not follow denies.
_case "cd inside \$(...) denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo \$(cd ${BEACON} && git commit -F ${TXT} )"
_case "cd inside backticks denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "x=\`cd ${BEACON} && git commit -F ${TXT} \`"
_case "! cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "! cd ${BEACON}; git commit -F ${TXT}"
_case "if cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "if cd ${BEACON}; then git commit -F ${TXT}; fi"
_case "builtin cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "builtin cd ${BEACON} && git commit -F ${TXT}"
_case "command cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "command cd ${BEACON} && git commit -F ${TXT}"
_case "bash -c with cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "bash -c \"cd ${BEACON} && git commit -F ${TXT} \""
_case "sh -c with cd denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "sh -c 'cd ${BEACON} && gh pr create --title t --body-file ${TXT} '"
_case "popd denies (the hook does not track the stack)" 2 "cd the hook cannot resolve" "${BEACON}" \
  "pushd ${PERSONAL} && popd && git commit -F ${TXT}"
_case "a path component named cd is not a cd" 0 "" "${PERSONAL}" \
  "ls ${TMP}/cd/x && git commit -F ${TXT}"
_case "{ cd B; commit; } still follows the cd" 2 "no Pangram check ran" "${PERSONAL}" \
  "{ cd ${BEACON}; git commit -F ${TXT}; }"

# Final review I3: several -C options deny.
_case "two git -C options deny" 2 "more than one git -C" "${TMP}" \
  "git -C personal -C ../beacon commit -F ${TXT}"
_case "one -C after -c still resolves" 2 "no Pangram check ran" "${PERSONAL}" \
  "git -c core.x=y -C ${BEACON} commit -F ${TXT}"

# Final review I2: the deny names what is missing. With no record the agent is
# told to run the check, not to stage and open again.
_run "${BEACON}" "git commit -F ${TXT}"
if ((rc == 2)) && [[ "${err}" == *"reason:  gate-review: rule 2 (pangram): no Pangram check ran"* &&
  "${err}" == *"Run the personify check"* && "${err}" == *"pangram_check.py"* &&
  "${err}" != *"Write the text to a file"* && "${err}" != *"has not been visually approved"* ]]; then
  _ok "no record: deny says run the check, not stage/open"
else
  _no "no record: deny says run the check, not stage/open (rc=${rc}): ${err}"
fi
PLUG="${TMP}/plug"
mkdir -p "${PLUG}/scripts" "${HOME}/.claude/plugins"
: >"${PLUG}/scripts/pangram_check.py"
cp "${TMP}/personify/scripts/length_check.py" "${PLUG}/scripts/"
jq -n --arg p "${PLUG}" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${HOME}/.claude/plugins/installed_plugins.json"
_case "no record: deny prints the installed check command" 2 \
  "python3 ${PLUG}/scripts/pangram_check.py < ${TXT}" "${BEACON}" "git commit -F ${TXT}"
printf '%s\n' "${STUB_PLUGINS}" >"${HOME}/.claude/plugins/installed_plugins.json"
printf 'never approved\n' >"${TMP}/unapproved.txt"
UREC="${XDG_CONFIG_HOME}/personify/checks/$(sha256sum "${TMP}/unapproved.txt" | cut -d' ' -f1).json"
printf '{"status":"FAIL","verdict":"AI"}\n' >"${UREC}"
_run "${BEACON}" "git commit -F ${TMP}/unapproved.txt"
if ((rc == 2)) && [[ "${err}" == *"verdict AI recorded; no visual approval matches"* &&
  "${err}" == *"stage --kind <kind> <label>"* ]]; then
  _ok "record but no approval: deny names the verdict and keeps the stage/open steps"
else
  _no "record but no approval: deny names the verdict and keeps the stage/open steps (rc=${rc}): ${err}"
fi
rm -f "${UREC}"

# Unchanged behaviour.
_norec
_case "inline -m still blocks" 2 "text given inline" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -m hello"
_case "relative message path still blocks" 2 "is not absolute" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -F msg.txt"
printf 'unapproved\n' >"${TMP}/other.txt"
# The reason is now check's own line (I2), not the hook's generic sentence.
_case "unapproved bytes still block" 2 "rule 3 (visual): no visual approval matches" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -F ${TMP}/other.txt"

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
