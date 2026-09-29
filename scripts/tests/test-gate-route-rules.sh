#!/usr/bin/env bash
# Tests for the rules parser and matcher in scripts/gate-route.sh
# (_load_rules, _match_rule) and the shipped gate-rules.conf.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/gate-route.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

# expect_match <label> <rules-file> <repo> <author> <expected "outcome<TAB>n">
expect_match() {
  local label="$1" file="$2" repo="$3" author="$4" want="$5" out rc got
  _load_rules "${file}" 2>/dev/null || {
    bad "${label}: load failed"
    return
  }
  out="$(_match_rule "${repo}" "${author}" 2>&1)"
  rc=$?
  got="$(printf '%s' "${out}" | cut -f1,2)"
  if [[ ${rc} -eq 0 && "${got}" == "${want}" ]]; then ok; else bad "${label}: rc=${rc} got '${got}' want '${want}'"; fi
}

# expect_load_fail <label> <rules-file> <needle>
expect_load_fail() {
  local label="$1" file="$2" needle="$3" err rc
  err="$(_load_rules "${file}" 2>&1 >/dev/null)"
  rc=$?
  if [[ ${rc} -eq 4 && "${err}" == *"${needle}"* ]]; then ok; else bad "${label}: rc=${rc} err='${err}' want needle '${needle}'"; fi
}

TAB=$'\t'
V="visual"
P="pangram"

RULES="${ROOT}/gate-rules.conf"
{
  expect_match "exact repo" "${RULES}" "andrewmrich/beacon-workspace" "andrewmrich" "${V}${TAB}1"
  expect_match "mixed case repo" "${RULES}" "AndrewMRich/Beacon-Workspace" "andrewmrich" "${V}${TAB}1"
  expect_match "other repo, author" "${RULES}" "other/beacon-workspace" "andrewmrich" "${P}${TAB}2"
  expect_match "twistedmelonman" "${RULES}" "twistedmelonman/x" "twistedmelonman" "${V}${TAB}3"
  expect_match "empty inputs" "${RULES}" "" "" "${V}${TAB}3"
}

# Reason strings
_load_rules "${ROOT}/gate-rules.conf"
check() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
out="$(_match_rule "andrewmrich/beacon-workspace" "x")"
check "reason repo" "${out##*"${TAB}"}" "matched repo=andrewmrich/beacon-workspace"
out="$(_match_rule "o/r" "AndrewMRich")"
check "reason author" "${out##*"${TAB}"}" "matched author=andrewmrich"
out="$(_match_rule "o/r" "z")"
check "reason default" "${out##*"${TAB}"}" "no rule matched, default"

# Messy file
printf '# comment\r\n\r\n  \t\r\nrepo=Foo/Bar\t \texempt  \r\n   # indented comment\r\n*   visual\t\r\n' >"${TMP}/messy.conf"
expect_match "messy exempt" "${TMP}/messy.conf" "foo/bar" "" "exempt${TAB}1"
expect_match "messy default" "${TMP}/messy.conf" "a/b" "" "${V}${TAB}2"

# Errors
printf 'repo=a/b visual\nrepo=a/b bogus\n' >"${TMP}/badoutcome.conf"
expect_load_fail "unknown outcome" "${TMP}/badoutcome.conf" "badoutcome.conf:2"
printf '# c\n\nbranch=x visual\n' >"${TMP}/badmatcher.conf"
expect_load_fail "unknown matcher" "${TMP}/badmatcher.conf" "badmatcher.conf:3"
printf 'repo=a/b visual\nvisual\n' >"${TMP}/onefield.conf"
expect_load_fail "one field" "${TMP}/onefield.conf" "onefield.conf:2"
expect_load_fail "missing file" "${TMP}/nope.conf" "nope.conf"

# No match
printf 'repo=a/b visual\n' >"${TMP}/nostar.conf"
_load_rules "${TMP}/nostar.conf"
err="$(_match_rule "x/y" "z" 2>&1 >/dev/null)"
rc=$?
if [[ ${rc} -eq 4 && "${err}" == *"no rule matched"* ]]; then ok; else bad "no match: rc=${rc} err='${err}'"; fi

# A parse error leaves the rule arrays empty, never a truncated set.
_load_rules "${TMP}/badoutcome.conf" 2>/dev/null
rule_arrays=(RULE_KIND RULE_VALUE RULE_OUTCOME)
dump="$(declare -p "${rule_arrays[@]}")"
check "arrays reset on error" "${dump//$'\n'/;}" "declare -a RULE_KIND=();declare -a RULE_VALUE=();declare -a RULE_OUTCOME=()"

# _match_rule tolerates a missing second argument under set -u.
_load_rules "${ROOT}/gate-rules.conf"
out="$(_match_rule "x/y" 2>&1)"
IFS="${TAB}" read -r o_outcome o_rule _ <<<"${out}"
check "one-arg match" "${o_outcome}${TAB}${o_rule}" "${V}${TAB}3"

echo "passed=${PASS} failed=${FAIL}"
[[ ${FAIL} -eq 0 ]]
