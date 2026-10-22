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
# real gate dir (so no SUSPENDED file), no real approvals.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
# gate-review.sh finds length_check.py through installed_plugins.json here;
# keep it off the real one.
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
# Copy gate off: these suites do not test it (copy-paths-none.conf says why).
export COPY_PATHS_FILE="${GATE_GH%/*}/copy-paths-none.conf"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
# Fixed rules: BEACON is review and PERSONAL exempt, so unapproved text tells
# them apart. THIRD is a gated cwd that is not Beacon.
export GATE_RULES_FILE="${TMP}/rules.conf"
cat >"${GATE_RULES_FILE}" <<'RULES'
repo=andrewmrich/beacon-workspace exempt
owner=twistedmelonman exempt
author=andrewmrich review
* review
RULES
# _stub_personify: a length_check.py that passes everything.
# shellcheck source=/dev/null
source "${GATE_GH%/*}/stub-personify.sh"
_stub_personify "${CLAUDE_CONFIG_DIR}" "${TMP}/personify"

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
THIRD="${TMP}/third"
_mkrepo "${THIRD}" someone-else/z
_mkrepo "${BEACON}" beacon-biosignals/x
_mkrepo "${PERSONAL}" twistedmelonman/y
_mkrepo "${WORKSPACE}" andrewmrich/beacon-workspace

# The text lives outside approved/; _approve puts the same bytes there.
TXT="${TMP}/msg"
printf 'fix(x): the text under test\n' >"${TXT}"
_approve() { cp "${TXT}" "${GATE_REVIEW_DIR}/approved/k1/msg"; }
_unapprove() { rm -f "${GATE_REVIEW_DIR}/approved/k1/msg"; }

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

_unapprove
_case "git -C review repo, unapproved: blocked" 2 "no visual approval matches" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_approve
_case "git -C review repo, approved: passes" 0 "" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_unapprove
_case "git -C exempt repo, unapproved: passes" 0 "" "${TMP}" \
  "git -C ${PERSONAL} commit -F ${TXT}"
_case "commit with no -C uses the hook cwd (review)" 2 "no visual approval matches" "${BEACON}" \
  "git commit -F ${TXT}"
_case "commit with no -C uses the hook cwd (exempt)" 0 "" "${PERSONAL}" \
  "git commit -F ${TXT}"
_case "relative -C resolves against the hook cwd" 2 "no visual approval matches" "${TMP}" \
  "git -C beacon commit -F ${TXT}"
_case "commit -C <sha> is not a directory" 2 "no visual approval matches" "${BEACON}" \
  "git commit -C abc123 -F ${TXT}"
_case "-C with a variable blocks" 2 "cannot resolve the repository" "${TMP}" \
  "git -C \$R commit -F ${TXT}"

_case "gh pr create -R review repo, unapproved: blocked" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R beacon-biosignals/x"
_case "gh --repo=... review repo: blocked" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} --repo=beacon-biosignals/x"
_case "gh pr create from the beacon-workspace checkout: passes, unapproved" 0 "" "${WORKSPACE}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh pr create from a personal checkout: passes, unapproved" 0 "" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh pr create from a beacon checkout: blocked, unapproved" 2 "no visual approval matches" "${BEACON}" \
  "gh pr create --title t --body-file ${TXT}"
_case "gh api repos/o/n path names the destination" 2 "no visual approval matches" "${PERSONAL}" \
  "gh api repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT}"
_case "gh api without a repo path uses the hook cwd" 0 "" "${PERSONAL}" \
  "gh api user/foo -F body=@${TXT}"

# The trust test: text that passed in an exempt repo must not publish to a
# review repo just because it passed there.
_case "passed in an exempt repo, committed to a review repo: blocked" 2 "no visual approval matches" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"
_approve
_case "same, once approved: passes" 0 "" "${TMP}" \
  "git -C ${BEACON} commit -F ${TXT}"

# Fix round 1: destinations the hook cannot resolve must not fall to the weaker
# rule. Each of these runs from an exempt cwd with unapproved text, so a silent
# fallthrough would pass (rc 0).
_unapprove
_case "gh -R with a variable blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R \$REPO"
_case "gh api repos/\$OWNER/\$NAME blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh api repos/\$OWNER/\$NAME/issues/1/comments -F body=@${TXT}"
_case "gh api repos/\$SLUG blocks" 2 "cannot resolve the repository" "${PERSONAL}" \
  "gh api repos/\${SLUG}/issues/1/comments -F body=@${TXT}"

_case "cd <review repo> && git commit follows the cd" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON} && git commit -F ${TXT}"
_case "cd <review repo> && gh pr create follows the cd" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON} && gh pr create --title t --body-file ${TXT}"
_case "cd inside a subshell denies (parentheses with a cd)" 2 "cd combined with parentheses" "${PERSONAL}" \
  "(cd ${BEACON} && git commit -F ${TXT} )"
_case "relative cd resolves against the cwd" 2 "no visual approval matches" "${TMP}" \
  "cd beacon && git commit -F ${TXT}"
_case "pushd follows the cd" 2 "no visual approval matches" "${PERSONAL}" \
  "pushd ${BEACON} && git commit -F ${TXT}"
_case "last cd wins (back to a exempt repo)" 0 "" "${BEACON}" \
  "cd ${BEACON} && cd ${PERSONAL} && git commit -F ${TXT}"
_case "cd to a exempt repo from a review cwd passes" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && git commit -F ${TXT}"
_case "git -C after cd resolves against the cd target" 2 "no visual approval matches" "${TMP}" \
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
_case "cd in a closed subshell, then commit from a review cwd: blocked" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && true); git commit -F ${TXT}"
_case "cd in a closed subshell, then gh pr create: blocked" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && true); gh pr create --title t --body-file ${TXT}"
_case "quoted unbalanced ( inside the subshell cannot mask the close" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && echo \"(x\" && true); git commit -F ${TXT}"
_case "commit in the same group as its cd now denies" 2 "cd combined with parentheses" "${PERSONAL}" \
  "( cd ${BEACON} && git commit -F ${TXT} )"
_case "plain cd, no parentheses, still resolves to the target (review)" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON} && git commit -F ${TXT}"
_case "plain cd, no parentheses, still resolves to the target (exempt)" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && git commit -F ${TXT}"
_case "parentheses with no cd are unaffected" 0 "" "${PERSONAL}" \
  "(echo hi) && git commit -F ${TXT}"
_case "parentheses with no cd are unaffected (review still routes by cwd)" 2 "no visual approval matches" "${BEACON}" \
  "(echo hi) && git commit -F ${TXT}"

# Final review C1: every gh destination form is read, and the ones the hook
# cannot read deny. Each runs with unapproved text, so a fall to the exempt cwd
# would pass (rc 0).
_unapprove
NOREPO="${TMP}/norepo"
mkdir -p "${NOREPO}"
URL="https://github.com/beacon-biosignals/x"
_case "gh pr comment <URL> from a personal cwd routes to the URL" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr comment ${URL}/pull/5 --body-file ${TXT}"
_case "gh pr comment <URL> from a non-repo cwd routes to the URL" 2 "no visual approval matches" "${NOREPO}" \
  "gh pr comment ${URL}/pull/5 --body-file ${TXT}"
_case "gh issue comment <URL> routes to the URL" 2 "no visual approval matches" "${PERSONAL}" \
  "gh issue comment ${URL}/issues/5 --body-file ${TXT}"
_case "gh pr review <URL> --comment routes to the URL" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr review ${URL}/pull/5 --comment --body-file ${TXT}"
_case "gh pr edit <URL> routes to the URL" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr edit ${URL}/pull/5 --body-file ${TXT}"
_case "-R github.com/o/n is normalized" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R github.com/beacon-biosignals/x"
_case "-R https://github.com/o/n is normalized" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R ${URL}"
_case "-R with mixed case is normalized" 2 "no visual approval matches" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R Beacon-Biosignals/X"
_case "-R URL and a matching <URL> argument agree" 2 "no visual approval matches" "${PERSONAL}" \
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
_case "title carrying -R cannot steer away from a review cwd" 2 "inside quoted text" "${BEACON}" \
  "gh pr create --title \"see -R twistedmelonman/y\" --body-file ${TXT}"
_case "title carrying -R cannot override a real -R" 2 "inside quoted text" "${PERSONAL}" \
  "gh pr create -R beacon-biosignals/x --title \"x -R twistedmelonman/y\" --body-file ${TXT}"
_case "title carrying a github.com URL denies" 2 "inside quoted text" "${BEACON}" \
  "gh pr create --title \"port of github.com/twistedmelonman/y\" --body-file ${TXT}"
_case "two -R that disagree deny" 2 "more than one repository" "${PERSONAL}" \
  "gh pr create -R beacon-biosignals/x -R twistedmelonman/y --title t --body-file ${TXT}"
_case "a <URL> and a -R that disagree deny" 2 "more than one repository" "${PERSONAL}" \
  "gh pr comment ${URL}/pull/5 -R twistedmelonman/y --body-file ${TXT}"
_case "an unquoted github.com value with no -R also checks the review cwd" 2 "no visual approval matches" "${BEACON}" \
  "gh pr comment https://github.com/twistedmelonman/y/pull/5 --body-file ${TXT}"
_case "a personal <URL> from a personal cwd passes" 0 "" "${PERSONAL}" \
  "gh pr comment https://github.com/twistedmelonman/y/pull/5 --body-file ${TXT}"
_case "gh api repositories/<id> denies" 2 "by number" "${PERSONAL}" \
  "gh api repositories/12345/issues/1/comments -F body=@${TXT}"
_case "gh api repos/{owner}/{repo} uses the cwd (review)" 2 "no visual approval matches" "${BEACON}" \
  "gh api repos/{owner}/{repo}/issues/1/comments -F body=@${TXT}"
_case "gh api repos/{owner}/{repo} uses the cwd (exempt)" 0 "" "${PERSONAL}" \
  "gh api repos/{owner}/{repo}/issues/1/comments -F body=@${TXT}"
_case "gh api full api.github.com URL names the repo" 2 "no visual approval matches" "${PERSONAL}" \
  "gh api https://api.github.com/repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT}"
_case "gh api repos/o/n with a field naming another repo denies" 2 "more than one repository" "${PERSONAL}" \
  "gh api repos/beacon-biosignals/x/issues/1/comments -F body=@${TXT} -f ref=https://github.com/twistedmelonman/y"
RTXT="${TMP}/repos/twistedmelonman/y/msg"
mkdir -p "${RTXT%/*}"
cp "${TXT}" "${RTXT}"
_case "a /repos/o/n inside the body file path is not an endpoint" 2 "no visual approval matches" "${BEACON}" \
  "gh api user/x -F body=@${RTXT}"
_case "repos/{owner}/{repo} plus a repos/ path in the body file still checks the cwd" 2 "no visual approval matches" "${BEACON}" \
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
_case "{ cd B; commit; } still follows the cd" 2 "no visual approval matches" "${PERSONAL}" \
  "{ cd ${BEACON}; git commit -F ${TXT}; }"

# The word cd inside an inert gh title or body value is text, not a cd: it
# routes like any other title. Anything that could run still counts.
_unapprove
_case "cd in a single-quoted -R title routes by the repo" 2 "no visual approval matches" "${PERSONAL}" \
  "gh issue create -R beacon-biosignals/x --title 'relative cd in scripts' --body-file ${TXT}"
_case "cd in a double-quoted title with no -R routes by the cwd (review)" 2 "no visual approval matches" "${BEACON}" \
  "gh issue create --title \"about cd\" --body-file ${TXT}"
_case "cd in a --title= value routes by the cwd (exempt)" 0 "" "${PERSONAL}" \
  "gh issue create --title='about cd' --body-file ${TXT}"
_case "cd in an inline -b body is text too" 2 "text given inline" "${THIRD}" \
  "gh issue comment 1 -b 'run cd first'"
_case "a real unresolved cd before gh -R still denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "cd \$X && gh issue create -R twistedmelonman/y --title t --body-file ${TXT}"
_case "cd inside \$(...) in a double-quoted title still counts" 2 "" "${PERSONAL}" \
  "gh issue create --title \"x \$(cd ${BEACON} && pwd)\" --body-file ${TXT}"
_case "an inert title does not hide a cd later in the command" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --title 'cd' --body-file ${TXT}; bash -c 'cd ${BEACON} && git commit -F ${TXT}'"
_case "ssh -t with a quoted cd still denies (not a gh title)" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "ssh -t 'cd ${BEACON}' && git commit -F ${TXT}"
# Commit-review finding: a -t inside one literal must not pair with the next
# literal's quote and swallow a live cd between them.
_case "a -t inside a literal does not swallow a live \$(cd ...)" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --title t --body-file ${TXT} 'a -t ' \$(cd ${BEACON} && git commit -F ${TXT}) ' b'"
_case "a -t inside a literal does not swallow a cd after a separator" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue comment 1 -b \"q\" -t \"x\" ' -t ' ; echo \$(cd ${BEACON}) ; echo ' '"
_case "a literal -t pairs only with its own quote" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --body-file ${TXT} 'x -t ' cd ' y' ; echo \$(cd ${BEACON})"
_case "a -t inside a literal does not swallow a backtick cd" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --title t --body-file ${TXT} 'a -t ' \`cd ${BEACON} && git commit -F ${TXT}\` ' b'"
_case "a -t inside a literal does not swallow a double-quoted \$(cd ...)" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --title t --body-file ${TXT} 'a -t ' \"\$(cd ${BEACON} && git commit -F ${TXT})\" ' b'"
_case "an escaped quote in a double-quoted title does not desync the scan" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "gh issue create --title \"a\\\" -b 'x\" ; echo \$(cd ${BEACON}) ; echo '\" --body-file ${TXT}"

# claude-config#742: the word cd inside a literal printf or echo argument is
# text too. Anything that could run it, or hide a cd, still counts.
_unapprove
_case "#742 reproducer: cd in a printf literal, then commit, routes by -C" 0 "" "${PERSONAL}" \
  "printf '%s\n' 'fix(env): x' '' 'kept the value for its own cd calls.' > ${TMP}/m.txt; git -C ${PERSONAL} commit -F ${TXT}"
_case "cd in a double-quoted echo literal routes by the cwd (exempt)" 0 "" "${PERSONAL}" \
  "echo \"run cd first\" > ${TMP}/m.txt && git commit -F ${TXT}"
_case "cd in an echo literal routes by the cwd (review)" 2 "no visual approval matches" "${BEACON}" \
  "echo 'about cd' > ${TMP}/m.txt; git commit -F ${TXT}"
_case "a real cd after a printf literal cd is still followed" 2 "no visual approval matches" "${PERSONAL}" \
  "printf 'cd' > ${TMP}/m.txt; cd ${BEACON} && git commit -F ${TXT}"
_case "printf -v is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf -v c 'cd ${BEACON}'; git commit -F ${TXT}"
_case "printf -v then \$c is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf -v c 'cd ${BEACON}'; \$c; git commit -F ${TXT}"
_case "printf -vc (attached) is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf -vc 'cd ${BEACON}'; git commit -F ${TXT}"
_case "echo piped into bash is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' | bash; git commit -F ${TXT}"
_case "echo piped into /bin/sh is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' | /bin/sh; git commit -F ${TXT}"
_case "echo into a file that is sourced with . is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' > ${TMP}/s; . ${TMP}/s; git commit -F ${TXT}"
_case "echo into a file that is sourced is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' > ${TMP}/s; source ${TMP}/s; git commit -F ${TXT}"
_case "a command with eval is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' > ${TMP}/s; eval true; git commit -F ${TXT}"
_case "echo piped into xargs is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' | xargs true; git commit -F ${TXT}"
_case "an unquoted echo cd still denies" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo cd /tmp; git commit -F ${TXT}"
_case "a printf literal with \$ still counts" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf '%s' \"cd \$X\"; git commit -F ${TXT}"
_case "a command that runs a file through \$(...) is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf 'cd ${BEACON}' > ${TMP}/s; \$(cat ${TMP}/s); git commit -F ${TXT}"
_case "a printf that also holds a gated command is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf '%s\n' 'cd ${BEACON}' 'git commit -F ${TXT}' | fish"
_case "a quoted newline in a printf literal is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf '%s\n' 'cd ${BEACON}"$'\n'"git commit -F ${TXT}' | fish"
_case "nested quoting in an echo segment keeps every cd" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' <(true); git commit -F ${TXT}"
_case "an echo segment that matches gh_re is not subtracted twice" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo -t 'cd' 'gh issue create ' ; echo \$(cd ${BEACON} && git commit -F ${TXT})"
_case "a backslash-split source is still source" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' > ${TMP}/s; s\\ource ${TMP}/s; git commit -F ${TXT}"
_case "a quote-split bash is still bash" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' | ba''sh; git commit -F ${TXT}"
_case "a quoted '.' is still ." 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "echo 'cd ${BEACON}' > ${TMP}/s; '.' ${TMP}/s; git commit -F ${TXT}"
_case "printf with a backslashed -v is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf \\-v c 'cd ${BEACON}'; git commit -F ${TXT}"
_case "printf with a quoted -v is never exempt" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "printf '-v' c 'cd ${BEACON}'; git commit -F ${TXT}"
_case "env echo is not exempt (first word only)" 2 "cd the hook cannot resolve" "${PERSONAL}" \
  "env echo 'cd x' > ${TMP}/m.txt; git commit -F ${TXT}"

# #747: a quoted '; cd <dir>' is text. Inert echo text routes by the cwd; any other carrier denies.
_unapprove
_case "#747 reproducer: quoted '; cd <dir>' does not move the route" 2 "no visual approval matches" "${BEACON}" \
  "echo 'x; cd ${PERSONAL} '; git commit -F ${TXT}"
_case "#747: double-quoted '&& cd <dir>' does not move the route" 2 "no visual approval matches" "${BEACON}" \
  "echo \"x && cd ${PERSONAL} \"; git commit -F ${TXT}"
_case "#747: a quoted cd after a real cd keeps the real target" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON}; echo 'x; cd ${PERSONAL}'; git commit -F ${TXT}"
_case "#747: a quoted review cd does not move a exempt cwd either" 0 "" "${PERSONAL}" \
  "echo 'x; cd ${BEACON} '; git commit -F ${TXT}"
_case "#747: a quoted cd in a non-echo argument denies" 2 "cd the hook cannot resolve" "${BEACON}" \
  "ssh h 'x; cd ${PERSONAL} '; git commit -F ${TXT}"
_case "#747: a quoted cd after the gated segment denies" 2 "cd the hook cannot resolve" "${BEACON}" \
  "git commit -F ${TXT}; ssh h 'x; cd ${PERSONAL}'"
_case "#747: a cd in a heredoc body does not move the route" 2 "cd the hook cannot resolve" "${BEACON}" \
  "cat <<EOF >${TMP}/h"$'\n'"cd ${PERSONAL}"$'\n'"EOF"$'\n'"git commit -F ${TXT}"
_case "#747: an escaped ; before cd is text too" 2 "cd the hook cannot resolve" "${BEACON}" \
  "echo x\\; cd ${PERSONAL}; git commit -F ${TXT}"
_case "#747: a quoted newline before cd is text too" 2 "cd the hook cannot resolve" "${BEACON}" \
  "echo 'x"$'\n'"cd ${PERSONAL}'; git commit -F ${TXT}"
_case "#747: an escaped quote in \$'...' does not desync the scan" 2 "cd the hook cannot resolve" "${BEACON}" \
  "echo \$'\\'' 'x; cd ${PERSONAL}'; git commit -F ${TXT}"
_case "#747: a commented-out cd does not move the route" 2 "cd the hook cannot resolve" "${BEACON}" \
  "git commit -F ${TXT} # ; cd ${PERSONAL}"
_case "#747: an unquoted cd still routes by its target (exempt)" 0 "" "${BEACON}" \
  "cd ${PERSONAL}; git commit -F ${TXT}"
_case "#747: an unquoted cd still routes by its target (review)" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON}; git commit -F ${TXT}"
# The start flags must line up with _segments, or every cd would deny (its fail-closed fallback).
_case "#747: a real cd still routes past multibyte text" 2 "no visual approval matches" "${PERSONAL}" \
  "cd ${BEACON} && gh pr create --title 'é ✗ a' --body-file ${TXT}"
_case "#747: a real cd after a heredoc still routes by its target" 0 "" "${BEACON}" \
  "cat <<'EOF' >${TMP}/h"$'\n'"a; b"$'\n'"EOF"$'\n'"cd ${PERSONAL} && git commit -F ${TXT}"

# Final review I3: several -C options deny.
_case "two git -C options deny" 2 "more than one git -C" "${TMP}" \
  "git -C personal -C ../beacon commit -F ${TXT}"
_case "one -C after -c still resolves" 2 "no visual approval matches" "${PERSONAL}" \
  "git -c core.x=y -C ${BEACON} commit -F ${TXT}"

# Final review I2: an unapproved review text gets the stage/open steps only.
_unapprove
_run "${BEACON}" "git commit -F ${TXT}"
if ((rc == 2)) && [[ "${err}" == *"(review): no visual approval matches"* &&
  "${err}" == *"stage --kind <kind> <label>"* && "${err}" != *Pangram* &&
  "${err}" != *pangram_check* ]]; then
  _ok "unapproved: deny gives the stage/open steps and no Pangram step"
else
  _no "unapproved: deny gives the stage/open steps and no Pangram step (rc=${rc}): ${err}"
fi

# Unchanged behaviour, in a gated repo.
_case "inline -m still blocks" 2 "text given inline" "${THIRD}" \
  "git -C ${THIRD} commit -m hello"
_case "relative message path still blocks" 2 "is not absolute" "${THIRD}" \
  "git -C ${THIRD} commit -F msg.txt"
printf 'unapproved\n' >"${TMP}/other.txt"
# The reason is check's own line (I2), not the hook's generic sentence.
_case "unapproved bytes still block" 2 "rule 4 (review): no visual approval matches" "${THIRD}" \
  "git -C ${THIRD} commit -F ${TMP}/other.txt"
_case "an exempt repo passes inline -m" 0 "" "${PERSONAL}" \
  "git -C ${PERSONAL} commit -m hello"

# #739: an unresolved destination never reached the route, so the deny must
# say to name the repository, not print the approval steps.
_dest_msg() { # <label> <cwd> <command>
  _run "$2" "$3"
  if ((rc == 2)) && [[ "${err}" == *"cannot tell which repository this writes to"* &&
    "${err}" == *"Name it literally and retry"* && "${err}" != *"stage --kind"* &&
    "${err}" != *"has not been visually approved"* ]]; then
    _ok "$1"
  else
    _no "$1 (rc=${rc}): ${err}"
  fi
}
_dest_msg "git -C \$R: name-it message, no staging steps" "${TMP}" \
  "git -C \$R commit -F ${TXT}"
_dest_msg "unfollowable cd: name-it message, no staging steps" "${PERSONAL}" \
  "cd \$D && git commit -F ${TXT}"
_dest_msg "cd with parentheses: name-it message, no staging steps" "${PERSONAL}" \
  "cd ${BEACON} && gh pr create --title 'docs(x): t' --body-file ${TXT}"
_dest_msg "gh -R \$X: name-it message, no staging steps" "${PERSONAL}" \
  "gh pr create --title t --body-file ${TXT} -R \$X"
_dest_msg "xargs wrapper: name-it message, no staging steps" "${PERSONAL}" \
  "echo ${TXT} | xargs git commit -F"
# A resolved, gated destination keeps the approval steps.
_run "${THIRD}" "git -C ${THIRD} commit -F ${TMP}/other.txt"
if ((rc == 2)) && [[ "${err}" == *"This destination is gated"* && "${err}" == *"stage --kind"* &&
  "${err}" != *"Every commit message"* ]]; then
  _ok "gated destination: deny keeps the staging steps"
else
  _no "gated destination: deny keeps the staging steps (rc=${rc}): ${err}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
