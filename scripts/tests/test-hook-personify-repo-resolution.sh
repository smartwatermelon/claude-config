#!/usr/bin/env bash
# hook-block-personify.sh: `W=/repo; git -C $W` resolves, and a cd plus a quoted "fix(x)" paren is not denied.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
[[ -x "${HOOK}" ]] || {
  echo "cannot find hook at ${HOOK}" >&2
  exit 1
}
# Fixtures stay under one mktemp -d. Nothing here deletes anything.
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"

export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export GATE_GH
# Copy gate off: test-hook-personify-copy.sh covers it.
export COPY_PATHS_FILE="${HERE}/fixtures/copy-paths-none.conf"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
export GATE_RULES_FILE="${TMP}/rules.conf"
cat >"${GATE_RULES_FILE}" <<'RULES'
owner=twistedmelonman exempt
* review
RULES
# shellcheck source=/dev/null
source "${HERE}/fixtures/stub-personify.sh"
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
_mkrepo "${BEACON}" beacon-biosignals/x
_mkrepo "${PERSONAL}" twistedmelonman/y
TXT="${TMP}/scratchpad/msg.txt"
mkdir -p "${TMP}/scratchpad"
printf 'fix(x): the text under test\n' >"${TXT}"

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
# BEACON is review, PERSONAL exempt: unapproved text passes only if the destination resolved to PERSONAL.
REVIEW="no visual approval matches"

echo "--- cd, then a quoted paren: the cd is followed (inventory: 15 rows) ---"
_case "cd <exempt> && gh pr create -R --title \"fix(x): y\": passes" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && gh pr create -R twistedmelonman/y --head claude/fix-x --base main --title \"fix(gh-wrapper): read the endpoint\" --body-file ${TXT}"
_case "cd <review> && gh pr create --title \"fix(x): y\": routed to review" 2 "${REVIEW}" "${PERSONAL}" \
  "cd ${BEACON} && gh pr create --title \"fix(x): y\" --body-file ${TXT}"
_case "single-quoted paren" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && gh pr create --title 'docs(x): y' --body-file ${TXT}"
_case "paren in a heredoc body after the cd" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && cat > ${TMP}/scratchpad/n.txt <<'EOF'
feat(docs-tidy): a (parenthesized) line
EOF
git commit -F ${TXT}"
_case "paren after a comment mark" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && git commit -F ${TXT} # see fix(x)"
_case "escaped paren" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && find . \\( -name x \\) && git commit -F ${TXT}"

echo "--- cd with a real paren: still denied ---"
_case "subshell cd, then commit" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && true); git commit -F ${TXT}"
_case "cd, then a subshell" 2 "cd combined with parentheses" "${BEACON}" \
  "cd ${PERSONAL} && (git commit -F ${TXT})"
_case "cd, then \$( )" 2 "cd combined with parentheses" "${BEACON}" \
  "cd ${PERSONAL} && echo \$(true) && gh pr create --title \"fix(x): y\" --body-file ${TXT}"
_case "cd, then \"\$( )\" inside double quotes" 2 "cd combined with parentheses" "${BEACON}" \
  "cd ${PERSONAL} && echo \"\$(true)\" && git commit -F ${TXT}"
_case "cd, then \$( ) in an unquoted-delimiter heredoc" 2 "cd combined with parentheses" "${BEACON}" \
  "cd ${PERSONAL} && cat > ${TMP}/scratchpad/n.txt <<EOF
\$(true)
EOF
git commit -F ${TXT}"
_case "\$( ) text in a quoted-delimiter heredoc is not live" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && cat > ${TMP}/scratchpad/n.txt <<'EOF'
\$(true)
EOF
git commit -F ${TXT}"
_case "a quoted ( cannot hide a real )" 2 "cd combined with parentheses" "${BEACON}" \
  "(cd ${PERSONAL} && echo \"(x\" && true); git commit -F ${TXT}"
_case "cd inside \$( ) is still untracked" 2 "cannot resolve" "${BEACON}" \
  "echo \"\$(cd ${PERSONAL}; pwd)\"; git commit -F ${TXT}"

echo "--- git -C \$VAR set to a literal path at the start (inventory: 5 rows) ---"
_case "W=/abs; git -C \$W commit: exempt repo passes" 0 "" "${BEACON}" \
  "W=${PERSONAL}; git -C \$W status -sb | head -1; git -C \$W commit -F ${TXT}"
_case "W=/abs; git -C \"\$W\" commit: review repo is routed to review" 2 "${REVIEW}" "${PERSONAL}" \
  "W=${BEACON}; git -C \"\$W\" commit -F ${TXT}"
_case "\${W} form" 0 "" "${BEACON}" "W=${PERSONAL}; git -C \${W} commit -F ${TXT}"
_case "quoted value" 0 "" "${BEACON}" "W=\"${PERSONAL}\" && git -C \"\$W\" commit -F ${TXT}"
_case "\$S/sub suffix" 0 "" "${BEACON}" "S=${TMP}; mkdir -p \$S; git -C \$S/personal commit -F ${TXT}"
_case "cd /abs && W=\$PWD && git -C \"\$W\" commit" 0 "" "${BEACON}" \
  "cd ${PERSONAL} && W=\$PWD && git -C \"\$W\" commit -F ${TXT}"

echo "--- git -C \$VAR the hook cannot resolve: denied, naming the part ---"
_case "W=\$(pwd)" 2 "could not resolve \$W: assigned from a command substitution" "${PERSONAL}" \
  "W=\$(pwd); git -C \$W commit -F ${TXT}"
_case "never assigned" 2 "could not resolve \$D: not assigned in this command" "${PERSONAL}" \
  "git -C \"\$D\" commit -F ${TXT}"
_case "assignment hidden in a quoted string" 2 "cannot resolve the repository" "${BEACON}" \
  "echo \"x; W=${PERSONAL}; \"; git -C \$W commit -F ${TXT}"
_case "env-prefix assignment" 2 "cannot resolve the repository" "${BEACON}" \
  "W=${PERSONAL} git -C \$W commit -F ${TXT}"
_case "assignment after another command" 2 "cannot resolve the repository" "${BEACON}" \
  "ls; W=${PERSONAL}; git -C \$W commit -F ${TXT}"
_case "assignment in a subshell" 2 "cannot resolve the repository" "${BEACON}" \
  "(W=${PERSONAL}); git -C \$W commit -F ${TXT}"
_case "reassigned after another command" 2 "names W again" "${BEACON}" \
  "W=${PERSONAL}; ls; W=${BEACON}; git -C \$W commit -F ${TXT}"
_case "source later" 2 "builtin" "${BEACON}" \
  "W=${PERSONAL}; source ${TMP}/x.sh; git -C \$W commit -F ${TXT}"
_case "value with .." 2 "cannot resolve the repository" "${BEACON}" \
  "W=${BEACON}/../personal; git -C \$W commit -F ${TXT}"
_case "\$(...) -C value" 2 "a command substitution" "${BEACON}" \
  "W=${PERSONAL}; git -C \"\$(echo \$W)\" commit -F ${TXT}"

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
