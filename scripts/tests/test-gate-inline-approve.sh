#!/usr/bin/env bash
# Inline approval by `approve <code>`, the refusals, the no-GUI open, and the open -t editor fallback.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
GATE="${SCRIPTS}/gate-review.sh"
HOOK="${SCRIPTS}/hook-gate-inline-approve.sh"
DIRWRITE="${SCRIPTS}/hook-block-gate-dir-write.sh"
# shellcheck source=/dev/null
source "${HERE}/fixtures/stub-personify.sh"

TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}/.claude"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
export GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export COPY_PATHS_FILE="${HERE}/fixtures/copy-paths-none.conf"
export GATE_LINT_VALE="${HERE}/fixtures/vale-stub.sh"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf '* review\n' >"${GATE_RULES_FILE}"
_stub_personify "${CLAUDE_CONFIG_DIR}" "${TMP}/plug"

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

ALPHA="${TMP}/alpha"
BETA="${TMP}/beta"
for r in "${ALPHA}" "${BETA}"; do
  mkdir -p "${r}"
  git -C "${r}" init -q -b main
done

# _stage <repo> <name> <text>: stage text from repo; print the approve-code.
_stage() {
  printf '%s\n' "$3" >"${TMP}/$2.txt"
  (cd "$1" && bash "${GATE}" stage --kind commit "$2" "${TMP}/$2.txt" 2>/dev/null) |
    sed -n 's/^approve-code: //p'
}

# _prompt <text>: run the hook as Claude Code would; sets OUT and RC.
_prompt() {
  RC=0
  OUT="$(jq -n --arg p "$1" '{hook_event_name: "UserPromptSubmit", prompt: $p}' | "${HOOK}" 2>&1)" || RC=$?
}

# _approved <repo> <name>: 0 if check accepts the staged source file.
_approved() {
  (cd "$1" && bash "${GATE}" check "${TMP}/$2.txt" >/dev/null 2>&1)
}

_reset() {
  rm -rf "${GATE_REVIEW_DIR}"
}

echo "--- stage prints an approve-code ---"
_reset
code="$(_stage "${ALPHA}" c1 "fix(x): first text")"
if [[ "${code}" =~ ^[0-9a-f]{6}$ ]]; then _ok "code is 6 hex chars (${code})"; else _no "code is 6 hex chars (got '${code}')"; fi
want="$(bash "${GATE}" hash "${TMP}/c1.txt" | cut -c1-6)"
if [[ "${code}" == "${want}" ]]; then _ok "code is the start of the approval hash"; else _no "code is the start of the approval hash"; fi

echo "--- a matching code approves ---"
if _approved "${ALPHA}" c1; then _no "not approved before the reply"; else _ok "not approved before the reply"; fi
_prompt "approve ${code}"
if [[ "${RC}" == 0 ]]; then _ok "hook exits 0"; else _no "hook exits 0 (rc=${RC})"; fi
if _approved "${ALPHA}" c1; then _ok "approve <code>: check passes"; else _no "approve <code>: check passes"; fi
if [[ "${OUT}" == *systemMessage*approved* ]]; then _ok "Andrew is told it was approved"; else _no "Andrew is told it was approved: ${OUT}"; fi
if [[ ! -e "${GATE_REVIEW_DIR}/pending/alpha-main/c1" ]]; then _ok "pending item removed"; else _no "pending item removed"; fi

echo "--- case, spacing and several codes ---"
_reset
c2="$(_stage "${ALPHA}" c2 "fix(x): second")"
c3="$(_stage "${BETA}" c3 "fix(x): third")"
_prompt "  APPROVE ${c2^^}, ${c3} thanks"
if _approved "${ALPHA}" c2; then _ok "upper-case code approves"; else _no "upper-case code approves: ${OUT}"; fi
if _approved "${BETA}" c3; then _ok "second code (other repo) approves"; else _no "second code (other repo) approves"; fi

echo "--- refusals ---"
_reset
c4="$(_stage "${ALPHA}" c4 "fix(x): fourth")"
wrong="ffffff"
[[ "${c4}" != "${wrong}" ]] || wrong="eeeeee"
_prompt "approve ${wrong}"
if [[ "${RC}" == 0 ]]; then _ok "wrong code: hook exits 0"; else _no "wrong code: hook exits 0"; fi
if _approved "${ALPHA}" c4; then _no "wrong code: nothing approved"; else _ok "wrong code: nothing approved"; fi
if [[ "${OUT}" == *"nothing approved"* ]]; then _ok "wrong code: Andrew is told"; else _no "wrong code: Andrew is told: ${OUT}"; fi

for p in "approve ${c4} zz12zz" "approve ${c4} 12345" "approve ${c4}, abc"; do
  _prompt "${p}"
  if _approved "${ALPHA}" c4 || [[ "${OUT}" != *"nothing approved"* ]]; then _no "'${p}': nothing approved"; else
    _ok "'${p}': nothing approved"; fi
done
_prompt "approve ${c4} ${wrong}"
if _approved "${ALPHA}" c4; then _no "one good, one wrong: nothing approved"; else _ok "one good, one wrong: nothing approved"; fi

# The same text staged from two repos has one hash, so one code names two items.
_reset
s1="$(_stage "${ALPHA}" same "fix(x): same text")"
_stage "${BETA}" same "fix(x): same text" >/dev/null
_prompt "approve ${s1}"
if [[ "${OUT}" == *"matches 2"* ]]; then _ok "ambiguous code: refused"; else _no "ambiguous code: refused: ${OUT}"; fi
found="$(find "${GATE_REVIEW_DIR}/approved" -type f)"
if [[ -z "${found}" ]]; then _ok "ambiguous code: nothing approved"; else _no "ambiguous code: nothing approved"; fi

# A restage with new text under the same name gets a new code; the old one is dead.
_reset
old="$(_stage "${ALPHA}" r1 "fix(x): before")"
new="$(_stage "${ALPHA}" r1 "fix(x): after the edit")"
if [[ "${old}" != "${new}" ]]; then _ok "restage: new code"; else _no "restage: new code"; fi
_prompt "approve ${old}"
if _approved "${ALPHA}" r1; then _no "restage: old code approves nothing"; else _ok "restage: old code approves nothing"; fi

# Text changed after staging: the approval binds the staged bytes, not the file.
_reset
c5="$(_stage "${ALPHA}" c5 "fix(x): as staged")"
printf 'fix(x): changed later\n' >"${TMP}/c5.txt"
_prompt "approve ${c5}"
if _approved "${ALPHA}" c5; then _no "changed after staging: check refuses"; else _ok "changed after staging: check refuses"; fi

echo "--- prompts that are not an approval ---"
_reset
c6="$(_stage "${ALPHA}" c6 "fix(x): sixth")"
for p in "please approve ${c6}" "approve" "approve ${c6}0" "approve ${c6:0:5}" "approved ${c6}" "looks good"; do
  _prompt "${p}"
  if [[ "${RC}" == 0 && -z "${OUT}" ]] && ! _approved "${ALPHA}" c6; then
    _ok "'${p}': ignored"
  else
    _no "'${p}': ignored (rc=${RC} out=${OUT})"
  fi
done
_prompt ""
if [[ "${RC}" == 0 && -z "${OUT}" ]]; then _ok "empty prompt: ignored"; else _no "empty prompt: ignored"; fi
OUT="$(printf 'not json' | "${HOOK}" 2>&1)"
RC=$?
if [[ "${RC}" == 0 ]]; then _ok "bad JSON: exit 0"; else _no "bad JSON: exit 0 (rc=${RC})"; fi

echo "--- agents cannot approve (hook-block-gate-dir-write.sh) ---"
TILDE="~"
_agent() {
  jq -n --arg c "$1" '{tool_input: {command: $c}}' | "${DIRWRITE}" >/dev/null 2>&1
}
for c in "bash ${GATE} approve-hash ${c6}" "${TILDE}/.claude/scripts/gate-review.sh approve-hash ${c6}" \
  "G=${GATE}; \$G approve-hash ${c6}" "${GATE} \"approve-hash\" ${c6}" \
  "echo '{\"prompt\":\"approve ${c6}\"}' | ${HOOK}" "bash ${HOOK} < /tmp/p.json" \
  "${TILDE}/.claude/scripts/hook-gate-inline-approve.sh < /tmp/p.json"; do
  _agent "${c}"
  rc=$?
  if [[ "${rc}" == 2 ]]; then _ok "blocked: ${c}"; else _no "blocked: ${c} (rc=${rc})"; fi
done
for c in "git add scripts/hook-gate-inline-approve.sh" "bash scripts/tests/test-gate-inline-approve.sh" \
  "bash ${GATE} stage --kind commit c1 /tmp/x"; do
  _agent "${c}"
  rc=$?
  if [[ "${rc}" == 0 ]]; then _ok "allowed: ${c}"; else _no "allowed: ${c} (rc=${rc})"; fi
done

echo "--- open with no GUI prints codes and returns ---"
STUB="${TMP}/stub-bin"
mkdir -p "${STUB}"
cat >"${STUB}/launchctl" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_MGR:-Background}"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB}/pgrep"
# open: -a fails (app missing); -t plays the human and writes APPROVED.
cat >"${STUB}/open" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OPEN_LOG}"
[[ "$1" == "-a" ]] && exit 1
f="${*: -1}"
sed -i.bak 's/^# STATUS: PENDING/# STATUS: APPROVED/' "${f}" && rm -f "${f}.bak"
EOF
chmod +x "${STUB}"/*
export OPEN_LOG="${TMP}/open.log"
_reset
: >"${OPEN_LOG}"
c7="$(_stage "${ALPHA}" c7 "fix(x): seventh")"
RC=0
OUT="$(cd "${ALPHA}" && PATH="${STUB}:${PATH}" GATE_REVIEW_TIMEOUT=4 bash "${GATE}" open 2>&1)" || RC=$?
if [[ "${RC}" == 0 ]]; then _ok "no GUI: open exits 0"; else _no "no GUI: open exits 0 (rc=${RC}): ${OUT}"; fi
if [[ "${OUT}" == *"approve-code: ${c7}"* ]]; then _ok "no GUI: prints the code"; else _no "no GUI: prints the code: ${OUT}"; fi
if [[ "${OUT}" == *"fix(x): seventh"* ]]; then _ok "no GUI: prints the text"; else _no "no GUI: prints the text"; fi
if [[ "${OUT}" == *"reply \`approve <code>\` in chat"* ]]; then _ok "no GUI: says how to approve"; else _no "no GUI: says how to approve"; fi
if [[ ! -s "${OPEN_LOG}" ]]; then _ok "no GUI: no editor opened"; else _no "no GUI: no editor opened"; fi
if _approved "${ALPHA}" c7; then _no "no GUI: nothing approved"; else _ok "no GUI: nothing approved"; fi

echo "--- editor missing: open -t fallback ---"
RC=0
OUT="$(cd "${ALPHA}" && PATH="${STUB}:${PATH}" STUB_MGR=Aqua GATE_EDITOR=NoSuchEditor GATE_REVIEW_TIMEOUT=6 \
  bash "${GATE}" open 2>&1)" || RC=$?
if grep -q '^-a NoSuchEditor ' "${OPEN_LOG}"; then _ok "tries GATE_EDITOR first"; else _no "tries GATE_EDITOR first"; fi
if grep -q '^-t ' "${OPEN_LOG}"; then _ok "falls back to open -t"; else _no "falls back to open -t"; fi
if [[ "${RC}" == 0 ]] && _approved "${ALPHA}" c7; then _ok "fallback editor approval works"; else
  _no "fallback editor approval works (rc=${RC}): ${OUT}"; fi

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
