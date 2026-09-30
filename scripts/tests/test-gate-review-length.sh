#!/usr/bin/env bash
# gate-review.sh stage --kind and check --kind run personify's real length_check.py, copied from a checkout at run time.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

CHECKER_SRC="${PERSONIFY_CHECKOUT:-${HOME}/Developer/personify}/scripts/length_check.py"
if [[ ! -f "${CHECKER_SRC}" ]]; then
  echo "SKIP: no personify checkout at ${CHECKER_SRC} (set PERSONIFY_CHECKOUT)"
  exit 0
fi

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/gate-review.sh"
[[ -f "${GATE}" ]] || {
  echo "cannot find gate-review.sh at ${GATE}" >&2
  exit 1
}
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'repo=acme/pang pangram\nrepo=acme/ex exempt\n* visual\n' >"${GATE_RULES_FILE}"
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"

# personify, installed where installed_plugins.json says.
PLUG="${TMP}/plug"
mkdir -p "${PLUG}/scripts" "${HOME}/.claude/plugins"
cp "${CHECKER_SRC}" "${PLUG}/scripts/length_check.py"
: >"${PLUG}/scripts/pangram_check.py"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
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

_load() {
  local src
  src="$(sed -n '/^_die()/,$p' "${GATE}" || true)"
  src="$(sed '/^case "${1:-}"/,$d' <<<"${src}" || true)"
  eval "${src}"
  GATE_DIR="${GATE_REVIEW_DIR}"
  export PENDING_ROOT="${GATE_DIR}/pending" APPROVED_ROOT="${GATE_DIR}/approved"
  export GATE_KEY="" PENDING="${PENDING_ROOT}" APPROVED="${APPROVED_ROOT}"
  ROUTE_SCRIPT="$(dirname "${GATE}")/gate-route.sh"
  export ROUTE_SCRIPT
  local ttl_line var
  for var in APPROVAL_TTL BUFFER_TTL; do
    ttl_line="$(grep -m1 "^${var}=" "${GATE}")"
    eval "${ttl_line}"
  done
}
_load

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
VIS="${TMP}/vis"
PANG="${TMP}/pang"
EX="${TMP}/ex"
_mkrepo "${VIS}" acme/other
_mkrepo "${PANG}" acme/pang
_mkrepo "${EX}" acme/ex

_chars() { printf "%${1}s" '' | tr ' ' x; }

SHORT="${TMP}/short.txt"
printf 'fix(x): short enough\n\nA body well under the cap.\n' >"${SHORT}"
LONG="${TMP}/long.txt"
C60="$(_chars 60)"
printf '%s\n\nbody\n' "${C60}" >"${LONG}"

# _stage_case <label> <want-rc> <want-substring> <dir> <args...>
_stage_case() {
  local label="$1" wrc="$2" wsub="$3" dir="$4" out rc
  shift 4
  out="$( (cd "${dir}" && _cmd_stage "$@") 2>&1)"
  rc=$?
  if ((rc == wrc)) && [[ "${out}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${out}"
  fi
}
_pending() {
  local key
  key="$(cd "$1" && _batch_key)" || return 1
  [[ -e "${PENDING_ROOT}/${key}/$2" ]]
}

# --- stage ---------------------------------------------------------------------
_stage_case "stage without --kind fails" 1 "--kind" "${VIS}" nokind "${SHORT}"
if ! _pending "${VIS}" nokind; then
  _ok "stage without --kind stages nothing"
else
  _no "stage without --kind stages nothing"
fi
_stage_case "stage with an unknown --kind fails" 1 "unknown --kind" "${VIS}" \
  --kind novel badkind "${SHORT}"
_stage_case "under-cap text stages on a visual route" 0 "staged: ok1" "${VIS}" \
  --kind commit ok1 "${SHORT}"
_stage_case "--kind after the name is accepted too" 0 "staged: ok2" "${VIS}" \
  ok2 --kind commit "${SHORT}"
_stage_case "over-cap text is refused on a visual route" 1 \
  "gate-review: commit title: 60/50 over by 10" "${VIS}" --kind commit vlong "${LONG}"
if ! _pending "${VIS}" vlong; then
  _ok "over-cap refusal stages nothing"
else
  _no "over-cap refusal stages nothing"
fi
out="$( (cd "${PANG}" && _cmd_stage --kind commit plong "${LONG}") 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"over by 10"* && "${out}" != *"no Pangram check record"* ]]; then
  _ok "pangram route: the refusal is the length one, not the record one"
else
  _no "pangram route: the refusal is the length one, not the record one (rc=${rc}): ${out}"
fi
_stage_case "pangram route, under cap, no record: record refusal as before" 1 \
  "no Pangram check record" "${PANG}" --kind commit pshort "${SHORT}"
_stage_case "exempt route stages over-cap text" 0 "staged: elong" "${EX}" \
  --kind commit elong "${LONG}"
# The kind picks the cap: 200 characters pass as a PR body, not as a PR comment.
B200="${TMP}/b200.txt"
_chars 200 >"${B200}"
_stage_case "200 chars stage as a pr body" 0 "staged: pr200" "${VIS}" --kind pr pr200 "${B200}"
_stage_case "200 chars are refused as a pr-comment" 1 "pr-comment body: 200/140 over by 60" \
  "${VIS}" --kind pr-comment c200 "${B200}"

# Checker errors are refusals that say so, not "rewrite shorter".
out="$( (cd "${VIS}" && CLAUDE_CONFIG_DIR="${TMP}/nowhere" _cmd_stage --kind commit noplug "${SHORT}") 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"checker error"* && "${out}" == *"personify is not installed"* ]]; then
  _ok "no personify install: stage refuses as a checker error"
else
  _no "no personify install: stage refuses as a checker error (rc=${rc}): ${out}"
fi
BROKEN="${TMP}/broken"
mkdir -p "${BROKEN}/scripts" "${TMP}/broken-cfg/plugins"
: >"${BROKEN}/scripts/pangram_check.py"
printf 'import sys\nprint("length_check: internal error: boom", file=sys.stderr)\nsys.exit(5)\n' \
  >"${BROKEN}/scripts/length_check.py"
jq -n --arg p "${BROKEN}" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${TMP}/broken-cfg/plugins/installed_plugins.json"
out="$( (cd "${VIS}" && CLAUDE_CONFIG_DIR="${TMP}/broken-cfg" _cmd_stage --kind commit exit5 "${SHORT}") 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"checker error"* && "${out}" == *"internal error: boom"* ]] &&
  ! _pending "${VIS}" exit5; then
  _ok "checker exit 5: stage refuses as a checker error with its stderr"
else
  _no "checker exit 5: stage refuses as a checker error with its stderr (rc=${rc}): ${out}"
fi
NOCHK="${TMP}/nochk"
mkdir -p "${NOCHK}/scripts" "${TMP}/nochk-cfg/plugins"
: >"${NOCHK}/scripts/pangram_check.py"
jq -n --arg p "${NOCHK}" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${TMP}/nochk-cfg/plugins/installed_plugins.json"
out="$( (cd "${VIS}" && CLAUDE_CONFIG_DIR="${TMP}/nochk-cfg" _cmd_stage --kind commit nochk "${SHORT}") 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"checker error"* && "${out}" == *"length_check.py"* ]]; then
  _ok "personify without length_check.py: stage refuses as a checker error"
else
  _no "personify without length_check.py: stage refuses as a checker error (rc=${rc}): ${out}"
fi

# The real entry point, as an agent runs it.
out="$(cd "${VIS}" && bash "${GATE}" stage --kind commit viamain "${SHORT}" 2>&1)"
rc=$?
if ((rc == 0)) && [[ "${out}" == *"staged: viamain"* ]]; then
  _ok "gate-review.sh stage --kind through the dispatcher"
else
  _no "gate-review.sh stage --kind through the dispatcher (rc=${rc}): ${out}"
fi

# --- personify-path --------------------------------------------------------------
out="$(bash "${GATE}" personify-path 2>&1)"
rc=$?
if ((rc == 0)) && [[ "${out}" == "${PLUG}" ]]; then
  _ok "personify-path prints the install directory"
else
  _no "personify-path prints the install directory (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/nowhere" bash "${GATE}" personify-path 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"personify is not installed"* ]]; then
  _ok "personify-path exits 1 with the not-installed message"
else
  _no "personify-path exits 1 with the not-installed message (rc=${rc}): ${out}"
fi

# --- check ------------------------------------------------------------------------
mkdir -p "${APPROVED_ROOT}/k1"
cp "${LONG}" "${APPROVED_ROOT}/k1/long"
cp "${SHORT}" "${APPROVED_ROOT}/k1/short"
# _check_case <label> <want-rc> <want-substring> <args...>
_check_case() {
  local label="$1" wrc="$2" wsub="$3" out rc
  shift 3
  out="$(_cmd_check "$@" 2>&1 >/dev/null)"
  rc=$?
  if ((rc == wrc)) && [[ "${out}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${out}"
  fi
}
_check_case "check --kind: approved but over cap fails" 1 \
  "gate-review: over length: commit title: 60/50 over by 10" --kind commit "${LONG}" --dir "${VIS}"
_check_case "check --kind: approved and under cap passes" 0 "" --kind commit "${SHORT}" --dir "${VIS}"
_check_case "check without --kind: over-cap approved text passes as today" 0 "" "${LONG}"
_check_case "check without --kind, with --dir: no length check" 0 "" "${LONG}" --dir "${VIS}"
_check_case "check --kind on an exempt route: no length check" 0 "" --kind commit "${LONG}" --dir "${EX}"
_check_case "check --kind with no destination flags still measures" 1 "over length" \
  --kind commit "${LONG}"
_check_case "check with an unknown --kind fails" 1 "unknown --kind" --kind novel "${SHORT}"
out="$(CLAUDE_CONFIG_DIR="${TMP}/broken-cfg" _cmd_check --kind commit "${SHORT}" --dir "${VIS}" 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"length checker error"* && "${out}" == *"boom"* ]]; then
  _ok "check --kind: checker exit 5 is a checker-error refusal"
else
  _no "check --kind: checker exit 5 is a checker-error refusal (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/nowhere" _cmd_check --kind commit "${SHORT}" --dir "${VIS}" 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"length checker error"* ]]; then
  _ok "check --kind: no personify is a checker-error refusal"
else
  _no "check --kind: no personify is a checker-error refusal (rc=${rc}): ${out}"
fi

# --- measure ----------------------------------------------------------------------
# Through the dispatcher, so the script's own set -euo pipefail is in force: a
# silent checker must come back as exit 2, never as a shell exit.
SILENT="${TMP}/silent"
mkdir -p "${SILENT}/scripts" "${TMP}/silent-cfg/plugins"
: >"${SILENT}/scripts/pangram_check.py"
printf 'import sys\nsys.exit(5)\n' >"${SILENT}/scripts/length_check.py"
jq -n --arg p "${SILENT}" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
  >"${TMP}/silent-cfg/plugins/installed_plugins.json"
T71="$(_chars 71)"
# _measure_case <label> <want-rc> <want-substring> <stdin-file> <args...>
_measure_case() {
  local label="$1" wrc="$2" wsub="$3" in="$4" out rc
  shift 4
  out="$(bash "${GATE}" measure "$@" <"${in}" 2>&1)"
  rc=$?
  if ((rc == wrc)) && [[ "${out}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${out}"
  fi
}
_measure_case "measure: a short title fits" 0 "" /dev/null --kind pr --title short
_measure_case "measure: a 71-char title is over, lines prefixed" 1 \
  "gate-review: pr title: 71/70 over by 1" /dev/null --kind pr --title "${T71}"
_measure_case "measure: --title= form" 1 "pr title: 71/70" /dev/null --kind pr "--title=${T71}"
_measure_case "measure: a title starting with - is a value, not a flag" 0 "" /dev/null \
  --kind pr --title "-x fix"
_measure_case "measure: a body on stdin under the cap fits" 0 "" "${B200}" --kind pr
_measure_case "measure: a body on stdin over the cap" 1 "gate-review: pr-comment body: 200/140" \
  "${B200}" --kind pr-comment
_measure_case "measure: no text at all is a usage error" 1 "no text" /dev/null --kind pr
_measure_case "measure: no --kind fails" 1 "--kind is required" /dev/null --title x
_measure_case "measure: exempt destination is not measured" 0 "" /dev/null \
  --kind pr --title "${T71}" --dir "${EX}"
_measure_case "measure: visual destination is measured" 1 "over by 1" /dev/null \
  --kind pr --title "${T71}" --dir "${VIS}"
out="$(CLAUDE_CONFIG_DIR="${TMP}/silent-cfg" bash "${GATE}" measure --kind pr --title x </dev/null 2>&1)"
rc=$?
if ((rc == 2)) && [[ "${out}" == *"length checker error"* && "${out}" == *"exited 5 with no message"* ]]; then
  _ok "measure: a silent checker (exit 5, no stderr) is exit 2, a checker error"
else
  _no "measure: a silent checker (exit 5, no stderr) is exit 2, a checker error (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/broken-cfg" bash "${GATE}" measure --kind pr --title x </dev/null 2>&1)"
rc=$?
if ((rc == 2)) && [[ "${out}" == *"boom"* ]]; then
  _ok "measure: checker exit 5 with a message is exit 2 with that message"
else
  _no "measure: checker exit 5 with a message is exit 2 with that message (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/nowhere" bash "${GATE}" measure --kind pr --title x </dev/null 2>&1)"
rc=$?
if ((rc == 2)) && [[ "${out}" == *"personify is not installed"* ]]; then
  _ok "measure: no personify is exit 2, a checker error"
else
  _no "measure: no personify is exit 2, a checker error (rc=${rc}): ${out}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
