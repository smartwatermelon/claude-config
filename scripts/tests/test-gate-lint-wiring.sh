#!/usr/bin/env bash
# gate-lint.sh as wired in: gate-review.sh stage (block or warn) and the personify hook's exempt branch.

# The gated outcome is "review" after the route rename and "visual" before it. The cases use whichever this gate-route.sh accepts.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
GATE="${SCRIPTS}/gate-review.sh"
HOOK="${SCRIPTS}/hook-block-personify.sh"
# shellcheck source=/dev/null
source "${HERE}/fixtures/stub-personify.sh"

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
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
export GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export COPY_PATHS_FILE="${HERE}/fixtures/copy-paths-none.conf"
export GATE_LINT_VALE="${HERE}/fixtures/vale-stub.sh"
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

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
GATED="${TMP}/gated"
EXEMPT="${TMP}/exempt"
_mkrepo "${GATED}" someone-else/y
_mkrepo "${EXEMPT}" smartwatermelon/z

# Use whichever gated outcome name this gate-route.sh accepts.
export GATE_RULES_FILE="${TMP}/rules.conf"
gated_name=""
for name in review visual; do
  printf 'owner=smartwatermelon exempt\n* %s\n' "${name}" >"${GATE_RULES_FILE}"
  if out="$(bash "${GATE}" route --kind commit --dir "${GATED}" 2>/dev/null)" &&
    [[ "${out}" == "${name}"* ]]; then
    gated_name="${name}"
    break
  fi
done
if [[ -n "${gated_name}" ]]; then
  _ok "rules file accepted with gated outcome '${gated_name}'"
else
  _no "neither review nor visual is a gated outcome gate-route.sh accepts"
fi

DASH="${TMP}/dash.txt"
printf 'fix: thing\n\nThis works \xe2\x80\x94 mostly.\n' >"${DASH}"
CLEAN="${TMP}/clean.txt"
printf 'fix: thing\n\nThis works.\n' >"${CLEAN}"

# _stage <dir> <args...>: run stage through the dispatcher, as an agent does.
_stage() {
  local dir="$1"
  shift
  (cd "${dir}" && bash "${GATE}" stage "$@") 2>&1
}
_pending_file() {
  find "${GATE_REVIEW_DIR}/pending" -path "*/$1" -type f 2>/dev/null | head -1
}

echo "--- stage on a gated route: block mode ---"
out="$(_stage "${GATED}" --kind commit dash1 "${DASH}")"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"error Andrew.Dashes"* && "${out}" == *"Nothing staged"* ]] &&
  [[ -z "$(_pending_file dash1 || true)" ]]; then
  _ok "an em dash is refused and nothing is staged"
else
  _no "an em dash is refused and nothing is staged (rc=${rc}): ${out}"
fi
out="$(_stage "${GATED}" --kind commit clean1 "${CLEAN}")"
rc=$?
if ((rc == 0)) && [[ "${out}" == *"staged: clean1"* ]]; then
  _ok "clean text stages"
else
  _no "clean text stages (rc=${rc}): ${out}"
fi
out="$(_stage "${GATED}" --kind commit --allow Dashes --reason "quoting a title" dash2 "${DASH}")"
rc=$?
side="$(_pending_file .lint/dash2 || true)"
if ((rc == 0)) && [[ "${out}" == *"staged: dash2"* && -n "${side}" ]] &&
  [[ "$(cat "${side}" || true)" == "Andrew.Dashes: quoting a title" ]]; then
  _ok "--allow with --reason stages, and the sidecar records the reason"
else
  _no "--allow with --reason stages, and the sidecar records the reason (rc=${rc}): ${out}"
fi
out="$(_stage "${GATED}" --kind commit --allow Dashes dash3 "${DASH}")"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"has no --reason"* ]] && [[ -z "$(_pending_file dash3 || true)" ]]; then
  _ok "--allow without --reason is refused"
else
  _no "--allow without --reason is refused (rc=${rc}): ${out}"
fi
# A restage without --allow must not keep the old reason.
out="$(_stage "${GATED}" --kind commit dash2 "${CLEAN}")"
rc=$?
if ((rc == 0)) && [[ -z "$(_pending_file .lint/dash2 || true)" ]]; then
  _ok "a restage without --allow drops the old sidecar"
else
  _no "a restage without --allow drops the old sidecar (rc=${rc}): ${out}"
fi
out="$(GATE_LINT_VALE="${TMP}/no-vale" _stage "${GATED}" --kind commit novale "${CLEAN}")"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"brew install vale"* ]] && [[ -z "$(_pending_file novale || true)" ]]; then
  _ok "missing vale on a gated route refuses to stage"
else
  _no "missing vale on a gated route refuses to stage (rc=${rc}): ${out}"
fi

echo "--- stage on an exempt route: warn mode ---"
out="$(_stage "${EXEMPT}" --kind commit dash4 "${DASH}")"
rc=$?
if ((rc == 0)) && [[ "${out}" == *"error Andrew.Dashes"* && "${out}" == *"staged: dash4"* ]]; then
  _ok "an em dash on an exempt route warns and stages"
else
  _no "an em dash on an exempt route warns and stages (rc=${rc}): ${out}"
fi

echo "--- hook exempt branch ---"
# _hook <cwd> <command>: prints "rc|stderr".
_hook() {
  local json err rc
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
  printf '%s|%s' "${rc}" "${err}"
}
res="$(_hook "${EXEMPT}" "git commit -F ${DASH}")"
if [[ "${res}" == "0|"*"error Andrew.Dashes"* ]]; then
  _ok "exempt commit with an em dash passes, with the lint finding on stderr"
else
  _no "exempt commit with an em dash passes, with the lint finding on stderr: ${res}"
fi
res="$(_hook "${EXEMPT}" "gh pr create -R smartwatermelon/z --title t --body-file ${DASH}")"
if [[ "${res}" == "0|"*"error Andrew.Dashes"* ]]; then
  _ok "exempt gh pr create body is linted as a pr, and passes"
else
  _no "exempt gh pr create body is linted as a pr, and passes: ${res}"
fi
res="$(_hook "${EXEMPT}" "git commit -F ${CLEAN}")"
if [[ "${res}" == "0|" ]]; then
  _ok "exempt commit with clean text passes silently"
else
  _no "exempt commit with clean text passes silently: ${res}"
fi
res="$(GATE_LINT_VALE="${TMP}/no-vale" _hook "${EXEMPT}" "git commit -F ${CLEAN}")"
if [[ "${res}" == "0|"*"vale is not installed"* ]]; then
  _ok "exempt commit with no vale passes, with one warning"
else
  _no "exempt commit with no vale passes, with one warning: ${res}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
