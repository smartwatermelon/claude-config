#!/usr/bin/env bash
# gate-lint.sh: block and warn modes, --allow/--reason, a missing vale, the real style.

# CI's Linux runner has no vale, so most cases use fixtures/vale-stub.sh.

# The last section runs the real vale on the real prose/.vale.ini, and skips without vale.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$(cd "${HERE}/.." && pwd)/gate-lint.sh"
[[ -x "${LINT}" ]] || {
  echo "cannot find an executable gate-lint.sh at ${LINT}" >&2
  exit 1
}
STUB="${HERE}/fixtures/vale-stub.sh"
# shellcheck source=/dev/null
source "${HERE}/fixtures/stub-personify.sh"

TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export GATE_REVIEW_DIR="${TMP}/gate"
export CLAUDE_CONFIG_DIR="${TMP}/cfg"
# A length_check.py that passes everything, so these cases test vale alone.
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

# _case <label> <want-rc> <want-substring> <vale> <args...>

# An empty want-substring matches anything. One starting with ! must NOT appear.
_case() {
  local label="$1" wrc="$2" wsub="$3" vale="$4" out rc ok=1
  shift 4
  out="$(GATE_LINT_VALE="${vale}" "${LINT}" "$@" 2>&1)"
  rc=$?
  ((rc == wrc)) || ok=0
  if [[ "${wsub}" == !* ]]; then
    [[ "${out}" != *"${wsub#!}"* ]] || ok=0
  else
    [[ "${out}" == *"${wsub}"* ]] || ok=0
  fi
  if ((ok == 1)); then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}, want ${wrc}): ${out}"
  fi
}

EM="${TMP}/em.txt"
printf 'fix: thing\n\nThis works \xe2\x80\x94 mostly.\n' >"${EM}"
PHRASE="${TMP}/phrase.txt"
printf 'fix: thing\n\nThis is a pivotal moment.\n' >"${PHRASE}"
# Thirty words, one sentence.
WORDS30="word1"
for i in {2..30}; do
  WORDS30+=" word${i}"
done
LONG="${TMP}/long.txt"
printf 'fix: thing\n\n%s.\n' "${WORDS30}" >"${LONG}"
CLEAN="${TMP}/clean.txt"
printf 'fix: thing\n\nThis works. The change is small.\n' >"${CLEAN}"
CONTRACT="${TMP}/contract.txt"
printf 'fix: thing\n\nWe do not ship it.\n' >"${CONTRACT}"

echo "--- block mode (stub vale) ---"
_case "em dash blocks" 1 "error Andrew.Dashes line 3" "${STUB}" commit "${EM}"
_case "banned phrase blocks" 1 "error Andrew.Phrases line 3" "${STUB}" commit "${PHRASE}"
_case "30-word sentence blocks" 1 "error Andrew.SentenceLength" "${STUB}" commit "${LONG}"
_case "clean text passes, silently" 0 "!gate-lint" "${STUB}" commit "${CLEAN}"
_case "a warning alone does not block" 0 "warning Andrew.Contractions" "${STUB}" commit "${CONTRACT}"
_case "--mode block is the default and explicit" 1 "Andrew.Dashes" "${STUB}" \
  --mode block commit "${EM}"

echo "--- --allow / --reason ---"
_case "--allow with a reason passes" 0 "allowed Andrew.Dashes line 3" "${STUB}" \
  --allow Dashes --reason "quoting a book title" commit "${EM}"
_case "--allow prints the reason for the caller" 0 \
  "allow Andrew.Dashes: quoting a book title" "${STUB}" \
  --allow Dashes --reason "quoting a book title" commit "${EM}"
_case "--allow takes the full check name too" 0 "allow Andrew.Dashes: r" "${STUB}" \
  --allow Andrew.Dashes --reason r commit "${EM}"
_case "--allow of one rule does not cover another" 1 "error Andrew.Phrases" "${STUB}" \
  --allow Dashes --reason r commit "${PHRASE}"
_case "--allow without --reason is a usage error" 64 "has no --reason" "${STUB}" \
  --allow Dashes commit "${EM}"
_case "--allow followed by another --allow is a usage error" 64 "has no --reason" "${STUB}" \
  --allow Dashes --allow Phrases --reason r commit "${EM}"
_case "--reason without --allow is a usage error" 64 "must follow an --allow" "${STUB}" \
  --reason r commit "${EM}"
_case "an empty --reason is a usage error" 64 "non-empty --reason" "${STUB}" \
  --allow Dashes --reason "  " commit "${EM}"
_case "--allow of an unknown rule is a usage error" 64 "no such rule" "${STUB}" \
  --allow Nope --reason r commit "${EM}"

echo "--- warn mode ---"
_case "warn mode prints errors and exits 0" 0 "error Andrew.Dashes" "${STUB}" \
  --mode warn commit "${EM}"
_case "warn mode: 30-word sentence still exits 0" 0 "Andrew.SentenceLength" "${STUB}" \
  --mode warn commit "${LONG}"

echo "--- missing vale ---"
_case "block mode: missing vale fails closed with an install hint" 2 "brew install vale" \
  "${TMP}/no-such-vale" commit "${CLEAN}"
_case "warn mode: missing vale warns and passes" 0 "warning: vale is not installed" \
  "${TMP}/no-such-vale" --mode warn commit "${CLEAN}"

echo "--- length caps ---"
# A length_check.py that reports an overrun, so the length half is tested too.
mkdir -p "${TMP}/over-cfg"
_stub_personify "${TMP}/over-cfg" "${TMP}/over-plug"
printf 'import sys\nprint("commit title: 60/50 over by 10")\nsys.exit(1)\n' \
  >"${TMP}/over-plug/scripts/length_check.py"
out="$(CLAUDE_CONFIG_DIR="${TMP}/over-cfg" GATE_LINT_VALE="${STUB}" "${LINT}" commit "${CLEAN}" 2>&1)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"gate-lint: commit title: 60/50 over by 10"* ]]; then
  _ok "a length overrun blocks"
else
  _no "a length overrun blocks (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/over-cfg" GATE_LINT_VALE="${STUB}" "${LINT}" copy "${CLEAN}" 2>&1)"
rc=$?
if ((rc == 0)); then
  _ok "copy has no length cap"
else
  _no "copy has no length cap (rc=${rc}): ${out}"
fi
out="$(CLAUDE_CONFIG_DIR="${TMP}/nowhere" GATE_LINT_VALE="${STUB}" "${LINT}" commit "${CLEAN}" 2>&1)"
rc=$?
if ((rc == 2)) && [[ "${out}" == *"personify is not installed"* ]]; then
  _ok "block mode: no personify is a tool error"
else
  _no "block mode: no personify is a tool error (rc=${rc}): ${out}"
fi

echo "--- copy extract ---"
COPY3="${TMP}/copy3.txt"
printf '>> a.md (added or changed text)\nFirst line.\nIt works \xe2\x80\x94 mostly.\n' >"${COPY3}"
_case "copy: a finding names the extract line, not vale's" 1 "error Andrew.Dashes line 3" \
  "${STUB}" copy "${COPY3}"
_case "commit: line numbers are unchanged" 1 "error Andrew.Dashes line 3" "${STUB}" commit "${EM}"

echo "--- usage ---"
_case "unknown kind is a usage error" 64 "unknown kind" "${STUB}" novel "${CLEAN}"
_case "missing file is a usage error" 64 "no such file" "${STUB}" commit "${TMP}/absent"
_case "bad --mode is a usage error" 64 "block or warn" "${STUB}" --mode loud commit "${CLEAN}"

echo "--- real vale, real prose/.vale.ini ---"
if command -v vale >/dev/null 2>&1; then
  REAL="$(command -v vale)"
  # One sample per rule: each must fire, at the level the rule sets.
  # _real <label> <want-substring> <text>
  _real() {
    local f="${TMP}/real-$((pass + fail)).txt"
    printf '%s\n' "$3" >"${f}"
    _case "real vale: $1" "$4" "$2" "${REAL}" commit "${f}"
  }
  _real "em dash" "error Andrew.Dashes" $'fix: x\n\nIt works \xe2\x80\x94 mostly.' 1
  _real "en dash" "error Andrew.Dashes" $'fix: x\n\nPages 3\xe2\x80\x934 changed.' 1
  _real "banned phrase" "error Andrew.Phrases" $'fix: x\n\nExperts say it helps.' 1
  _real "completion claim" "error Andrew.Phrases" $'fix: x\n\nThe branch is production ready.' 1
  _real "booster closer" "error Andrew.Phrases" $'fix: x\n\nHope this helps.' 1
  _real "STE substitution" "error Andrew.STE" $'fix: x\n\nWe utilize the cache.' 1
  _real "prior to" "error Andrew.STE" $'fix: x\n\nRun it prior to the push.' 1
  _real "30-word sentence" "error Andrew.SentenceLength" \
    $'fix: x\n\n'"${WORDS30}." 1
  _real "contraction is a warning only" "warning Andrew.Contractions" $'fix: x\n\nWe do not ship it.' 0
  _real "clean text passes" "!Andrew." $'fix: x\n\nThe change is small. It works.' 0
  _real "dash inside a code block is ignored" "!Andrew.Dashes" \
    $'fix: x\n\nRun this:\n\n```\na \xe2\x80\x94 b\n```' 0
  # Six header words and a 20-word sentence: one 26-word sentence if the lines were joined.
  WORDS20="word1"
  for i in {2..20}; do
    WORDS20+=" word${i}"
  done
  f="${TMP}/real-copy.txt"
  printf '>> README.md (added or changed text)\n%s.\n' "${WORDS20}" >"${f}"
  _case "real vale: copy lines are not joined into one sentence" 0 "!Andrew.SentenceLength" \
    "${REAL}" copy "${f}"
  _case "real vale: the same text as a commit is one sentence (control)" 1 \
    "error Andrew.SentenceLength" "${REAL}" commit "${f}"
else
  echo "  SKIP  real vale cases: vale is not installed here"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
