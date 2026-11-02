#!/usr/bin/env bash
# gate-review.sh --dir <abs path>: stage and open keyed to that repo, no cd (sandbox exclusion form).

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
GATE="${SCRIPTS}/gate-review.sh"
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
git -C "${BETA}" checkout -q -b feat-x
ELSEWHERE="${TMP}/elsewhere"
mkdir -p "${ELSEWHERE}"
printf 'fix(x): text\n' >"${TMP}/body.txt"

# _gate <args...>: run gate-review.sh from ELSEWHERE; sets OUT and RC.
_gate() {
  RC=0
  OUT="$(cd "${ELSEWHERE}" && bash "${GATE}" "$@" 2>&1)" || RC=$?
}

echo "--- --dir keys staging to that repo and branch ---"
_gate --dir "${ALPHA}" stage --kind commit c1 "${TMP}/body.txt"
if [[ "${RC}" == 0 ]]; then _ok "stage with --dir exits 0"; else _no "stage with --dir exits 0 (rc=${RC}): ${OUT}"; fi
if [[ -f "${GATE_REVIEW_DIR}/pending/alpha-main/c1" ]]; then _ok "staged under alpha-main"; else
  _no "staged under alpha-main: ${OUT}"; fi
_gate --dir "${BETA}" stage --kind commit c2 "${TMP}/body.txt"
if [[ -f "${GATE_REVIEW_DIR}/pending/beta-feat-x/c2" ]]; then _ok "a second repo keys to its own branch"; else
  _no "a second repo keys to its own branch: ${OUT}"; fi
keys="$(find "${GATE_REVIEW_DIR}/pending" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | paste -sd ' ' -)"
if [[ "${keys}" == "alpha-main beta-feat-x" ]]; then _ok "only the two --dir keys exist"; else
  _no "only the two --dir keys exist: [${keys}]"; fi

echo "--- --dir with a relative <file> is refused ---"
printf 'fix(x): repo copy\n' >"${ALPHA}/body.txt"
RC=0
OUT="$(cd "${TMP}" && bash "${GATE}" --dir "${ALPHA}" stage --kind commit rel body.txt 2>&1)" || RC=$?
if [[ "${RC}" != 0 && "${OUT}" == *"absolute path"* && ! -e "${GATE_REVIEW_DIR}/pending/alpha-main/rel" ]]; then
  _ok "relative file refused, nothing staged"
else
  _no "relative file refused, nothing staged (rc=${RC}): ${OUT}"
fi

echo "--- --dir with spaces in the path ---"
SPACED="${TMP}/my repo"
mkdir -p "${SPACED}"
git -C "${SPACED}" init -q -b main
_gate --dir "${SPACED}" stage --kind commit sp "${TMP}/body.txt"
if [[ "${RC}" == 0 && -f "${GATE_REVIEW_DIR}/pending/my-repo-main/sp" ]]; then _ok "spaced path stages"; else
  _no "spaced path stages (rc=${RC}): ${OUT}"; fi

echo "--- --dir reaches open: it shows that repo's items ---"
STUB="${TMP}/stub-bin"
mkdir -p "${STUB}"
printf '#!/usr/bin/env bash\necho Background\n' >"${STUB}/launchctl"
printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB}/pgrep"
chmod +x "${STUB}"/*
RC=0
OUT="$(cd "${ELSEWHERE}" && PATH="${STUB}:${PATH}" GATE_REVIEW_TIMEOUT=4 bash "${GATE}" --dir "${ALPHA}" open 2>&1)" || RC=$?
if [[ "${RC}" == 0 && "${OUT}" == *"fix(x): text"* ]]; then _ok "open --dir lists alpha's item"; else
  _no "open --dir lists alpha's item (rc=${RC}): ${OUT}"; fi
if [[ "${OUT}" != *"nothing staged"* ]]; then _ok "open --dir finds the staged item"; else _no "open --dir finds the staged item"; fi

echo "--- --dir refusals: nothing staged ---"
rm -rf "${GATE_REVIEW_DIR}"
_gate --dir alpha stage --kind commit r1 "${TMP}/body.txt"
if [[ "${RC}" != 0 && "${OUT}" == *"absolute"* ]]; then _ok "relative path refused"; else _no "relative path refused (rc=${RC}): ${OUT}"; fi
_gate --dir "${TMP}/no-such-dir" stage --kind commit r2 "${TMP}/body.txt"
if [[ "${RC}" != 0 && "${OUT}" == *"not a directory"* ]]; then _ok "missing directory refused"; else
  _no "missing directory refused (rc=${RC}): ${OUT}"; fi
_gate --dir
if [[ "${RC}" != 0 && "${OUT}" == *"--dir needs"* ]]; then _ok "--dir with no value refused"; else
  _no "--dir with no value refused (rc=${RC}): ${OUT}"; fi
left="$(find "${GATE_REVIEW_DIR}/pending" -type f 2>/dev/null || true)"
if [[ -z "${left}" ]]; then _ok "no refusal staged anything"; else
  _no "no refusal staged anything"; fi

echo "--- without --dir: unchanged, keyed to the cwd ---"
RC=0
OUT="$(cd "${ALPHA}" && bash "${GATE}" stage --kind commit c3 "${TMP}/body.txt" 2>&1)" || RC=$?
if [[ "${RC}" == 0 && -f "${GATE_REVIEW_DIR}/pending/alpha-main/c3" ]]; then _ok "cwd staging still works"; else
  _no "cwd staging still works (rc=${RC}): ${OUT}"; fi

echo "--- usage names --dir ---"
_gate
if [[ "${OUT}" == *"[--dir <abs path>]"* ]]; then _ok "usage shows --dir"; else _no "usage shows --dir: ${OUT}"; fi

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
