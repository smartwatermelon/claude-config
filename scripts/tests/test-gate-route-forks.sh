#!/usr/bin/env bash
# The 2026-10-08 routes (dev-env#154) through the hook and the shipped gate-rules.conf: forks, NOS, Netlify sites.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
HOOK="${SCRIPTS}/hook-block-personify.sh"
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
# No gh wrapper: authors are unresolved, so owner rules carry the routing.
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export GATE_GH
export GATE_RULES_FILE="${SCRIPTS}/../gate-rules.conf"
export GATE_TEST_FORKS="nightowlstudiollc/forked twistedmelonman/forkx beacon-biosignals/forked"
export GATE_TEST_GH_FAIL="nightowlstudiollc/broken smartwatermelon/offline"
export GATE_TEST_GH_LOG="${TMP}/gh.log"
# A length checker that passes everything, as in test-hook-personify-route.sh.
mkdir -p "${CLAUDE_CONFIG_DIR}/plugins" "${TMP}/personify/scripts"
: >"${TMP}/personify/scripts/pangram_check.py"
printf 'import sys\nsys.exit(0)\n' >"${TMP}/personify/scripts/length_check.py"
jq -n --arg p "${TMP}/personify" '{plugins:{"personify@personify":[{installPath:$p}]}}' \
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

_mkrepo() { # <dir> <owner/name> [extra remote owner/name]
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
  [[ -z "${3:-}" ]] || git -C "$1" remote add upstream "https://github.com/$3.git"
}
_mkrepo "${TMP}/nosfork" nightowlstudiollc/forked
_mkrepo "${TMP}/nosbroken" nightowlstudiollc/broken
_mkrepo "${TMP}/nos" nightowlstudiollc/site
_mkrepo "${TMP}/insomnia" smartwatermelon/projectinsomnia
_mkrepo "${TMP}/larry" smartwatermelon/crazy-larry
_mkrepo "${TMP}/workspace" andrewmrich/beacon-workspace
_mkrepo "${TMP}/bbfork" beacon-biosignals/forked
_mkrepo "${TMP}/tmfork" twistedmelonman/forkx
_mkrepo "${TMP}/swm" smartwatermelon/plain
_mkrepo "${TMP}/swmup" smartwatermelon/superpowers obra/superpowers
_mkrepo "${TMP}/offline" smartwatermelon/offline
TXT="${TMP}/msg.txt"
printf 'fix(x): text nobody approved\n' >"${TXT}"

# _case <label> <want-rc> <want-substring> <cwd> <command>
_case() {
  local label="$1" wrc="$2" wsub="$3" json err rc
  json="$(jq -n --arg c "$5" --arg d "$4" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}

# --- text inside the repo (commits) -----------------------------------------
_case "NOS fork: exempt" 0 "" "${TMP}/nosfork" "git commit -F ${TXT}"
_case "beacon fork: exempt" 0 "" "${TMP}/bbfork" "git commit -F ${TXT}"
_case "NOS fork lookup fails: gated (pangram)" 2 "no Pangram check ran" "${TMP}/nosbroken" "git commit -F ${TXT}"
_case "NOS non-fork: gated (pangram)" 2 "no Pangram check ran" "${TMP}/nos" "git commit -F ${TXT}"
_case "projectinsomnia: gated (pangram)" 2 "no Pangram check ran" "${TMP}/insomnia" "git commit -F ${TXT}"
_case "crazy-larry: gated (pangram)" 2 "no Pangram check ran" "${TMP}/larry" "git commit -F ${TXT}"
_case "beacon-workspace: exempt, even inline" 0 "" "${TMP}/workspace" "git commit -m 'notes'"
_case "twistedmelonman fork: exempt" 0 "" "${TMP}/tmfork" "git commit -F ${TXT}"

# --- gh text posted from a checkout -----------------------------------------
_case "upstream PR from a fork checkout, no -R: gated" 2 "no visual approval" "${TMP}/tmfork" \
  "gh pr create --title t --body-file ${TXT}"
_case "upstream PR from a fork checkout, -R parent: gated" 2 "no visual approval" "${TMP}/tmfork" \
  "gh pr create -R someone/upstream --title t --body-file ${TXT}"
_case "PR to the fork itself with -R: exempt" 0 "" "${TMP}/tmfork" \
  "gh pr create -R twistedmelonman/forkx --title t --body-file ${TXT}"
_case "NOS fork checkout, no -R: gated (the stricter route)" 2 "no visual approval" "${TMP}/nosfork" \
  "gh pr create --title t --body-file ${TXT}"
_case "NOS non-fork checkout, no -R: pangram kept" 2 "no Pangram check ran" "${TMP}/nos" \
  "gh pr create --title t --body-file ${TXT}"
_case "smartwatermelon non-fork checkout: exempt" 0 "" "${TMP}/swm" \
  "gh pr create --title t --body-file ${TXT}"
_case "smartwatermelon checkout with an upstream remote: gated" 2 "no visual approval" "${TMP}/swmup" \
  "gh pr create --title t --body-file ${TXT}"
_case "smartwatermelon checkout, lookup fails: gated" 2 "no visual approval" "${TMP}/offline" \
  "gh pr create --title t --body-file ${TXT}"
_case "lookup fails, commit is not gh-posted: exempt" 0 "" "${TMP}/offline" "git commit -F ${TXT}"

# --- the cache --------------------------------------------------------------
CACHE="${GATE_REVIEW_DIR}/fork-cache"
if [[ "$(cat "${CACHE}/twistedmelonman/forkx" 2>/dev/null)" == "true" ]]; then
  _ok "a fork answer is cached under gate-review/fork-cache"
else
  _no "a fork answer is cached under gate-review/fork-cache"
fi
if [[ ! -e "${CACHE}/smartwatermelon/offline" && ! -e "${CACHE}/nightowlstudiollc/broken" ]]; then
  _ok "a failed lookup is not cached"
else
  _no "a failed lookup is not cached"
fi
: >"${GATE_TEST_GH_LOG}"
_case "cached: smartwatermelon checkout still exempt" 0 "" "${TMP}/swm" \
  "gh pr create --title t --body-file ${TXT}"
if [[ ! -s "${GATE_TEST_GH_LOG}" ]]; then
  _ok "a cached answer makes no gh call"
else
  _no "a cached answer makes no gh call: $(tr '\n' ' ' <"${GATE_TEST_GH_LOG}")"
fi
printf 'garbage\n' >"${CACHE}/smartwatermelon/plain"
_case "a bad cache entry is looked up again" 0 "" "${TMP}/swm" \
  "gh pr create --title t --body-file ${TXT}"
if grep -qx 'smartwatermelon/plain' "${GATE_TEST_GH_LOG}"; then
  _ok "the bad entry caused a fresh lookup"
else
  _no "the bad entry caused a fresh lookup"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
