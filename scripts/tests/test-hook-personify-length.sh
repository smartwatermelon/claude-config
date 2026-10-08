#!/usr/bin/env bash
# hook-block-personify.sh: the length kind and titles come from the real command, measured by personify's real checker.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

CHECKER_SRC="${PERSONIFY_CHECKOUT:-${HOME}/Developer/personify}/scripts/length_check.py"
if [[ ! -f "${CHECKER_SRC}" ]]; then
  # CI must run this suite; a silent SKIP there hides the gap (claude-config#649).
  if [[ "${CI:-}" == "true" ]]; then
    echo "FAIL: CI=true but no personify checkout at ${CHECKER_SRC} (set PERSONIFY_CHECKOUT)" >&2
    exit 1
  fi
  echo "SKIP: no personify checkout at ${CHECKER_SRC} (set PERSONIFY_CHECKOUT)"
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
[[ -x "${HOOK}" ]] || {
  echo "cannot find hook at ${HOOK}" >&2
  exit 1
}
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'repo=acme/ex exempt\n* visual\n' >"${GATE_RULES_FILE}"

PLUG="${TMP}/plug"
mkdir -p "${PLUG}/scripts" "${CLAUDE_CONFIG_DIR}/plugins"
cp "${CHECKER_SRC}" "${PLUG}/scripts/length_check.py"
: >"${PLUG}/scripts/pangram_check.py"
jq -n --arg p "${PLUG}" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"

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

REPO="${TMP}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q
git -C "${REPO}" remote add origin "https://github.com/twistedmelonman/y.git"

_chars() { printf "%${1}s" '' | tr ' ' x; }
# SHORT fits every kind; B200 is over commit and pr-comment only; B300 passes only as an issue.
A="${GATE_REVIEW_DIR}/approved/k1"
SHORT="${A}/short"
B200="${A}/b200"
B300="${A}/b300"
printf 'fix(x): short\n' >"${SHORT}"
_chars 200 >"${B200}"
_chars 300 >"${B300}"
T70="$(_chars 70)"
C40="$(_chars 40)"
C68="$(_chars 68)"
T71="$(_chars 71)"

_run() {
  local json
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
}
# _case <label> <want-rc> <want-substring> <command>
_case() {
  local label="$1" wrc="$2" wsub="$3"
  _run "${REPO}" "$4"
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}

echo "=== bodies: one case per row of the kind table ==="
_case "git commit: over the commit cap" 2 "commit title: 200/50 over by 150" \
  "git commit -F ${B200}"
_case "git commit: under the cap passes" 0 "" "git commit -F ${SHORT}"
_case "gh pr create: 300 is over the pr cap" 2 "pr body: 300/280 over by 20" \
  "gh pr create --title t --body-file ${B300}"
_case "gh pr edit: 300 is over the pr cap" 2 "pr body: 300/280 over by 20" \
  "gh pr edit 5 --body-file ${B300}"
_case "gh pr create: 200 passes as pr" 0 "" "gh pr create --title t --body-file ${B200}"
_case "gh issue create: 300 passes as issue" 0 "" "gh issue create --title t --body-file ${B300}"
_case "gh issue edit: 300 passes as issue" 0 "" "gh issue edit 5 --body-file ${B300}"
_case "gh pr comment: 200 is over pr-comment" 2 "pr-comment body: 200/140 over by 60" \
  "gh pr comment 5 --body-file ${B200}"
_case "gh issue comment: 200 is over pr-comment" 2 "pr-comment body: 200/140 over by 60" \
  "gh issue comment 5 --body-file ${B200}"
_case "gh pr review: 200 is over pr-comment" 2 "pr-comment body: 200/140 over by 60" \
  "gh pr review 5 --comment --body-file ${B200}"
_case "gh api pulls/N/comments: 200 passes as line-comment" 0 "" \
  "gh api repos/twistedmelonman/y/pulls/5/comments -F body=@${B200}"
_case "gh api pulls/N/comments: 300 is over line-comment" 2 "line-comment body: 300/280" \
  "gh api repos/twistedmelonman/y/pulls/5/comments -F body=@${B300}"
_case "gh api issues/N/comments: 200 is over pr-comment" 2 "pr-comment body: 200/140" \
  "gh api repos/twistedmelonman/y/issues/5/comments -F body=@${B200}"
_case "gh api, neither path: checked as pr-comment" 2 "pr-comment body: 200/140" \
  "gh api user/x -F body=@${B200}"
PB="${TMP}/pulls/1/comments/b200"
mkdir -p "${PB%/*}"
cp "${B200}" "${PB}"
_case "a pulls/N/comments in the body file path is not the endpoint" 2 "pr-comment body: 200/140" \
  "gh api user/x -F body=@${PB}"
# A real stage as issue: 290 chars fit the issue body (no cap) and not the pr
# body (280). Approval is what open does on APPROVED: pending/<key>/<name>
# moves to approved/<key>/<name>.
I290="${TMP}/i290.txt"
_chars 290 >"${I290}"
staged="$(cd "${REPO}" && "${HERE}/../gate-review.sh" stage --kind issue i290 "${I290}" 2>&1)"
key="${staged##*(for }"
key="${key%)*}"
if [[ "${staged}" == *"staged: i290"* && -f "${GATE_REVIEW_DIR}/pending/${key}/i290" ]]; then
  _ok "a 290-char text stages as issue"
else
  _no "a 290-char text stages as issue: ${staged}"
fi
mkdir -p "${GATE_REVIEW_DIR}/approved/${key}"
mv "${GATE_REVIEW_DIR}/pending/${key}/i290" "${GATE_REVIEW_DIR}/approved/${key}/i290"
I290A="${GATE_REVIEW_DIR}/approved/${key}/i290"
_case "staged as issue, approved: gh issue create publishes it" 0 "" \
  "gh issue create --title t --body-file ${I290A}"
_case "staged as issue, published with gh pr create: rechecked as pr" 2 "pr body: 290/280 over by 10" \
  "gh pr create --title t --body-file ${I290A}"
_case "over length says so, not 'not visually approved'" 2 "over its length cap" \
  "gh pr comment 5 --body-file ${B200}"
_run "${REPO}" "gh pr comment 5 --body-file ${B200}"
if [[ "${err}" != *"has not been visually approved"* ]]; then
  _ok "over length deny does not claim a missing approval"
else
  _no "over length deny does not claim a missing approval: ${err}"
fi

echo "=== titles ==="
_case "a 70-char --title passes" 0 "" "gh pr create --title \"${T70}\" --body-file ${SHORT}"
_case "a 71-char --title on gh pr create is denied" 2 "pr title: 71/70 over by 1" \
  "gh pr create --title \"${T71}\" --body-file ${SHORT}"
_case "a 71-char title with no body flag is still denied" 2 "title: 71/70" \
  "gh pr edit 5 --title \"${T71}\""
_case "gh issue create -t 71 is denied" 2 "issue title: 71/70" \
  "gh issue create -t '${T71}' --body-file ${SHORT}"
_case "gh issue edit --title= 71 is denied" 2 "issue title: 71/70" \
  "gh issue edit 5 --title=${T71}"
_case "--title=\"...\" quoted form is measured" 2 "title: 71/70" \
  "gh pr edit 5 --title=\"${T71}\""
_case "gh pr comment ignores a -t it does not have" 0 "" \
  "gh pr comment 5 --body-file ${SHORT}"
_case "--title \"\$(cat f)\" is denied as unmeasurable" 2 "cannot be measured" \
  "gh pr create --title \"\$(cat /tmp/f)\" --body-file ${SHORT}"
_case "a backtick title is denied as unmeasurable" 2 "cannot be measured" \
  "gh pr edit 5 --title \"a \`cat f\`\""
_case "a \$VAR title is denied as unmeasurable" 2 "cannot be measured" \
  "gh pr edit 5 --title \$T"
_case "a \$'...' title is denied as unmeasurable" 2 "cannot be measured" \
  "gh pr edit 5 --title \$'abc'"
_case "attached -t<value> is denied" 2 "attached or combined -t" \
  "gh pr edit 5 -t${T71}"
_case "combined -dt is denied" 2 "attached or combined -t" \
  "gh pr create -dt short --body-file ${SHORT}"
_case "two title flags are denied" 2 "more than one title" \
  "gh pr edit 5 --title short --title \"${T71}\""
_case "a title that mentions -t is measured whole and passes" 0 "" \
  "gh pr edit 5 --title \"fix the -t flag\""
_case "a quoted ; in an over-long title is measured whole" 2 "title: 71/70" \
  "gh pr edit 5 --title \"a; ${C68}\""
_case "a quoted ; in a short title passes" 0 "" \
  "gh pr edit 5 --title \"a; b\""
_case "a title spanning two lines is measured whole" 2 "title: 81/70" \
  "gh pr edit 5 --title \"${C40}
${C40}\""
_case "escaped quotes inside the title are measured" 2 "title: 71/70" \
  "gh pr edit 5 --title \"\\\"${T70}\""
_case "concatenated quoting is measured whole" 2 "title: 72/70" \
  "gh pr edit 5 --title 'a'\\''${T70}'"
_case "an unquoted escaped ; title passes" 0 "" \
  "gh pr create --title a\\;b --body-file ${SHORT}"
_case "a title after a continuation is measured" 2 "title: 71/70" \
  "gh pr create --body-file ${SHORT} \\
  --title \"${T71}\""
_case "bash -c: an over-long title inside is measured" 2 "title: 71/70" \
  "bash -c \"gh pr edit 5 --title '${T71}'\""
_case "bash -c: a short title inside passes" 0 "" \
  "bash -c \"gh pr edit 5 --title 'short'\""
_case "bash -c: two commands, the second over-long" 2 "issue title: 71/70" \
  "bash -c \"gh pr edit 5 --title 'a'; gh issue edit 6 --title '${T71}'\""
_case "exempt destination: an over-long title is not measured" 0 "" \
  "gh pr edit 5 -R acme/ex --title \"${T71}\""
_case "exempt destination: an over-long gh issue create title is not measured" 0 "" \
  "gh issue create -R acme/ex --title \"${T71}\" --body-file ${SHORT}"
_case "non-exempt destination: the same title is denied" 2 "pr title: 71/70" \
  "gh pr edit 5 -R acme/other --title \"${T71}\""
_case "a cd leaves the destination unrouted, so the title is measured" 2 "pr title: 71/70" \
  "cd ${REPO} && gh pr edit 5 -R acme/ex --title \"${T71}\""
_case "a cd with a short title still passes" 0 "" \
  "cd ${REPO} && gh pr edit 5 --title short"
_case "prose: a title in an echo is not a gh call" 0 "" \
  "echo 'see gh pr create --title \"${T71}\"'"

echo "=== suspension and checker errors ==="
TODAY="$(date +%F)"
printf '%s\n' "${TODAY}" >"${GATE_REVIEW_DIR}/SUSPENDED"
_case "suspended: an over-long title passes" 0 "SUSPENDED" \
  "gh pr edit 5 --title \"${T71}\""
_case "suspended: an over-cap body passes" 0 "SUSPENDED" \
  "gh pr comment 5 --body-file ${B200}"
rm -f "${GATE_REVIEW_DIR}/SUSPENDED"
mv "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json" "${TMP}/ip.json"
_case "no personify: a title is denied as a checker error" 2 "checker error" \
  "gh pr edit 5 --title short"
_case "no personify: a body is denied as a checker error" 2 "checker error" \
  "gh pr comment 5 --body-file ${SHORT}"
_run "${REPO}" "gh pr comment 5 --body-file ${SHORT}"
if [[ "${err}" != *"has not been visually approved"* && "${err}" != *"over its length cap"* ]]; then
  _ok "checker error deny reads as neither unapproved nor over length"
else
  _no "checker error deny reads as neither unapproved nor over length: ${err}"
fi
mv "${TMP}/ip.json" "${CLAUDE_CONFIG_DIR}/plugins/installed_plugins.json"
printf 'import sys\nprint("length_check: internal error: boom", file=sys.stderr)\nsys.exit(5)\n' \
  >"${PLUG}/scripts/length_check.py"
_case "checker exit 5 on a title: checker error with its stderr" 2 "boom" \
  "gh pr edit 5 --title short"
_case "checker exit 5 on a body: checker error with its stderr" 2 "boom" \
  "git commit -F ${SHORT}"
# A checker that fails with nothing useful on stderr must still deny, labeled
# a checker error: an exit of 1 from the hook would not block the command.
printf 'import sys\nsys.exit(5)\n' >"${PLUG}/scripts/length_check.py"
_case "silent checker exit 5 on a title: checker-error deny" 2 "checker error" \
  "gh pr edit 5 --title short"
_case "silent checker exit 5 on a title with a body: checker-error deny" 2 "checker error" \
  "gh pr create --title short --body-file ${SHORT}"
printf 'import sys\nprint("usage: x", file=sys.stderr)\nsys.exit(5)\n' >"${PLUG}/scripts/length_check.py"
_case "usage-only checker exit 5 on a title: checker-error deny" 2 "checker error" \
  "gh pr edit 5 --title short"
_run "${REPO}" "gh pr edit 5 --title short"
if [[ "${err}" != *"over its length cap"* ]]; then
  _ok "usage-only checker error is not called an overrun"
else
  _no "usage-only checker error is not called an overrun: ${err}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
