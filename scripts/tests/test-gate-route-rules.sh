#!/usr/bin/env bash
# Tests for the rules parser and matcher in scripts/gate-route.sh
# (_load_rules, _match_rule) and the shipped gate-rules.conf.

set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
# The rule arrays are set by gate-route.sh; declared here so shellcheck sees them.
declare -a RULE_KIND RULE_VALUE RULE_OUTCOME
# shellcheck source=/dev/null
source "${ROOT}/scripts/gate-route.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# Fork lookups go to a stub, and the fork cache to the scratch dir.
export GATE_REVIEW_DIR="${TMP}/gate"
GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export GATE_GH

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}

# expect_match <label> <rules-file> <repo> <author> <expected "outcome<TAB>n"> [host]
expect_match() {
  local label="$1" file="$2" repo="$3" author="$4" want="$5" host="${6:-}" out rc got
  _load_rules "${file}" 2>/dev/null || {
    bad "${label}: load failed"
    return
  }
  out="$(_match_rule "${repo}" "${author}" "${host}" 2>&1)"
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
E="exempt"
GH="github.com"

RULES="${ROOT}/gate-rules.conf"
{
  # Decided 2026-10-08 (dev-env#154).
  expect_match "beacon-workspace exempt" "${RULES}" "andrewmrich/beacon-workspace" "andrewmrich" "${E}${TAB}1"
  expect_match "mixed case repo" "${RULES}" "AndrewMRich/Beacon-Workspace" "andrewmrich" "${E}${TAB}1"
  # Public sites: commit text is exempt; their pages go through copy-paths.conf.
  expect_match "projectinsomnia exempt" "${RULES}" "smartwatermelon/projectinsomnia" "twistedmelonman" "${E}${TAB}2" "${GH}"
  expect_match "crazy-larry exempt" "${RULES}" "smartwatermelon/crazy-larry" "twistedmelonman" "${E}${TAB}2" "${GH}"
  expect_match "other repo, author" "${RULES}" "other/beacon-workspace" "andrewmrich" "${P}${TAB}7"
  expect_match "twistedmelonman exempt" "${RULES}" "twistedmelonman/x" "twistedmelonman" "${E}${TAB}3" "${GH}"
  expect_match "empty inputs" "${RULES}" "" "" "${V}${TAB}10"
  expect_match "empty repo, github host" "${RULES}" "" "twistedmelonman" "${V}${TAB}10" "${GH}"
  # owner= rules: personal owners are exempt on github.com only.
  expect_match "owner smartwatermelon" "${RULES}" "smartwatermelon/x" "twistedmelonman" "${E}${TAB}2" "${GH}"
  expect_match "owner mixed case" "${RULES}" "SmartWatermelon/X" "twistedmelonman" "${E}${TAB}2" "GitHub.com"
  expect_match "nightowlstudiollc exempt" "${RULES}" "nightowlstudiollc/y" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "beacon-biosignals owner, author unresolved" "${RULES}" "beacon-biosignals/x" "" "${P}${TAB}8" "${GH}"
  # The known-bad cases: author resolves every unknown owner to twistedmelonman,
  # so only an owner rule can tell these apart, and none may match them.
  expect_match "third party stays gated" "${RULES}" "anthropics/claude-code" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "owner prefix only" "${RULES}" "smartwatermelonx/y" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "owner without name" "${RULES}" "smartwatermelon" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "owner with extra path" "${RULES}" "smartwatermelon/x/y" "twistedmelonman" "${V}${TAB}10" "${GH}"
  # Host must be github.com; unknown or other hosts fall through.
  expect_match "owner, no host" "${RULES}" "smartwatermelon/x" "twistedmelonman" "${V}${TAB}10"
  expect_match "owner, other host" "${RULES}" "smartwatermelon/x" "twistedmelonman" "${V}${TAB}10" "gitlab.com"
  expect_match "owner, lookalike host" "${RULES}" "smartwatermelon/x" "twistedmelonman" "${V}${TAB}10" "github.com.evil.example"
  # fork= rules (the stub answers): a proven fork is exempt, anything else is gated.
  export GATE_TEST_FORKS="nightowlstudiollc/forked beacon-biosignals/forked andrewmrich/forked anthropics/forked"
  export GATE_TEST_GH_FAIL="nightowlstudiollc/broken beacon-biosignals/broken"
  expect_match "NOS fork exempt" "${RULES}" "nightowlstudiollc/forked" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "beacon fork exempt" "${RULES}" "beacon-biosignals/forked" "andrewmrich" "${E}${TAB}5" "${GH}"
  expect_match "andrewmrich fork exempt" "${RULES}" "andrewmrich/forked" "andrewmrich" "${E}${TAB}6" "${GH}"
  expect_match "third-party fork gated" "${RULES}" "anthropics/forked" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "NOS fork lookup fails: owner rule, exempt" "${RULES}" "nightowlstudiollc/broken" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "beacon fork lookup fails: gated" "${RULES}" "beacon-biosignals/broken" "andrewmrich" "${P}${TAB}7" "${GH}"
  expect_match "NOS non-fork exempt" "${RULES}" "nightowlstudiollc/site" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "fork rule needs github.com" "${RULES}" "nightowlstudiollc/forked" "twistedmelonman" "${V}${TAB}10" "gitlab.com"
  unset GATE_TEST_FORKS GATE_TEST_GH_FAIL
  # Private repos: Beacon stays gated, NOS is exempt by owner, third parties fall to *.
  export GATE_TEST_PRIVATE="beacon-biosignals/secret nightowlstudiollc/kebab-tax andrewmrich/secret anthropics/secret smartwatermelon/secret nightowlstudiollc/broken"
  export GATE_TEST_GH_FAIL="nightowlstudiollc/broken"
  expect_match "private beacon repo, andrewmrich: gated" "${RULES}" "beacon-biosignals/secret" "andrewmrich" "${P}${TAB}7" "${GH}"
  expect_match "private beacon repo, author unresolved: gated" "${RULES}" "beacon-biosignals/secret" "" "${P}${TAB}8" "${GH}"
  expect_match "private beacon repo, other author: gated" "${RULES}" "beacon-biosignals/secret" "twistedmelonman" "${P}${TAB}8" "${GH}"
  expect_match "private andrewmrich repo: gated" "${RULES}" "andrewmrich/secret" "" "${P}${TAB}9" "${GH}"
  expect_match "andrewmrich text in a NOS repo: exempt" "${RULES}" "nightowlstudiollc/kebab-tax" "andrewmrich" "${E}${TAB}4" "${GH}"
  expect_match "private NOS repo: exempt" "${RULES}" "nightowlstudiollc/kebab-tax" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "private NOS repo, mixed case: exempt" "${RULES}" "NightOwlStudioLLC/Kebab-Tax" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "private third-party repo: gated (falls to *)" "${RULES}" "anthropics/secret" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "public NOS repo: exempt" "${RULES}" "nightowlstudiollc/tnjcleaning" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "NOS private lookup fails: exempt" "${RULES}" "nightowlstudiollc/broken" "twistedmelonman" "${E}${TAB}4" "${GH}"
  expect_match "public third-party repo: gated" "${RULES}" "anthropics/claude-code" "twistedmelonman" "${V}${TAB}10" "${GH}"
  expect_match "public smartwatermelon repo: exempt as before" "${RULES}" "smartwatermelon/plain" "twistedmelonman" "${E}${TAB}2" "${GH}"
  expect_match "private repo on another host: gated" "${RULES}" "nightowlstudiollc/kebab-tax" "twistedmelonman" "${V}${TAB}10" "gitlab.com"
  expect_match "private repo, no host: gated" "${RULES}" "nightowlstudiollc/kebab-tax" "twistedmelonman" "${V}${TAB}10"
  unset GATE_TEST_PRIVATE GATE_TEST_GH_FAIL
  # Earlier rules still win.
  expect_match "workspace repo before author" "${RULES}" "andrewmrich/beacon-workspace" "andrewmrich" "${E}${TAB}1" "${GH}"
}

# Fail-closed invariant: an unknown answer skips a fork= or private= rule,
# so no other rule after the first of them may be exempt.
_load_rules "${RULES}"
seen_lookup=0
for i in "${!RULE_KIND[@]}"; do
  case "${RULE_KIND[i]}" in
    fork | private) seen_lookup=1 ;;
    *)
      if ((seen_lookup)) && [[ "${RULE_OUTCOME[i]}" == "exempt" ]]; then
        bad "rule $((i + 1)) is exempt below a fork= or private= rule"
      fi
      ;;
  esac
done
ok
# The Beacon rules must come before every private= rule, or a private Beacon
# repo would be exempt.
vis=0 beacon_last=0
for i in "${!RULE_KIND[@]}"; do
  case "${RULE_KIND[i]}:${RULE_VALUE[i]}" in
    private:*) ((vis == 0)) && vis=$((i + 1)) ;;
    author:andrewmrich | owner:beacon-biosignals | owner:andrewmrich) beacon_last=$((i + 1)) ;;
    *) ;;
  esac
done
if ((beacon_last > 0 && (vis == 0 || beacon_last < vis))); then ok; else bad "Beacon rules (last ${beacon_last}) not above the first private= rule (${vis})"; fi

# private= takes a login, like fork=: no slash, no empty value, any case.
printf 'private=a/b exempt\n* visual\n' >"${TMP}/privslash.conf"
expect_load_fail "private with slash" "${TMP}/privslash.conf" "privslash.conf:1"
printf 'private= exempt\n* visual\n' >"${TMP}/privempty.conf"
expect_load_fail "private empty" "${TMP}/privempty.conf" "privempty.conf:1"
printf 'private=NightOwlStudioLLC exempt\n* visual\n' >"${TMP}/privcase.conf"
export GATE_TEST_PRIVATE="nightowlstudiollc/kebab-tax"
expect_match "private login case-insensitive" "${TMP}/privcase.conf" "nightowlstudiollc/kebab-tax" "" "${E}${TAB}1" "${GH}"
# The shipped rules no longer use private=, so its fail-closed cases live here.
export GATE_TEST_PRIVATE="nightowlstudiollc/kebab-tax nightowlstudiollc/broken"
export GATE_TEST_GH_FAIL="nightowlstudiollc/broken"
expect_match "private= public repo: no match" "${TMP}/privcase.conf" "nightowlstudiollc/site" "" "${V}${TAB}2" "${GH}"
expect_match "private= lookup fails: no match" "${TMP}/privcase.conf" "nightowlstudiollc/broken" "" "${V}${TAB}2" "${GH}"
expect_match "private= other host: no match" "${TMP}/privcase.conf" "nightowlstudiollc/kebab-tax" "" "${V}${TAB}2" "gitlab.com"
unset GATE_TEST_PRIVATE GATE_TEST_GH_FAIL

# The private= cache: answers are kept under private-cache, failures are not.
export GATE_TEST_PRIVATE="nightowlstudiollc/cached" GATE_TEST_GH_FAIL="nightowlstudiollc/down"
GATE_TEST_GH_LOG="${TMP}/gh.log"
export GATE_TEST_GH_LOG
_is_private nightowlstudiollc/cached
check_rc=$?
_is_private nightowlstudiollc/down
down_rc=$?
if ((check_rc == 0 && down_rc == 2)); then ok; else bad "_is_private rc: cached=${check_rc} down=${down_rc}"; fi
cached="$(cat "${GATE_REVIEW_DIR}/private-cache/nightowlstudiollc/cached" 2>/dev/null || true)"
if [[ "${cached}" == "true" ]]; then ok; else bad "private answer not cached"; fi
if [[ ! -e "${GATE_REVIEW_DIR}/private-cache/nightowlstudiollc/down" ]]; then ok; else bad "failed lookup was cached"; fi
: >"${GATE_TEST_GH_LOG}"
_is_private nightowlstudiollc/cached
if [[ ! -s "${GATE_TEST_GH_LOG}" ]]; then ok; else bad "cached private answer made a gh call"; fi
GATE_PRIVATE_CACHE_TTL=0 _is_private nightowlstudiollc/cached
if grep -qx 'nightowlstudiollc/cached' "${GATE_TEST_GH_LOG}"; then ok; else bad "expired private answer not looked up again"; fi
unset GATE_TEST_PRIVATE GATE_TEST_GH_FAIL GATE_TEST_GH_LOG

# A fork= value with a slash is a parse error, like owner=.
printf 'fork=a/b exempt\n* visual\n' >"${TMP}/slashfork.conf"
expect_load_fail "fork with slash" "${TMP}/slashfork.conf" "slashfork.conf:1"

# Reason strings
_load_rules "${ROOT}/gate-rules.conf"
check() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
out="$(_match_rule "andrewmrich/beacon-workspace" "x")"
check "reason repo" "${out##*"${TAB}"}" "matched repo=andrewmrich/beacon-workspace"
out="$(_match_rule "o/r" "AndrewMRich")"
check "reason author" "${out##*"${TAB}"}" "matched author=andrewmrich"
out="$(_match_rule "o/r" "z")"
check "reason default" "${out##*"${TAB}"}" "no rule matched, default"
out="$(_match_rule "smartwatermelon/x" "z" "github.com")"
check "reason owner" "${out##*"${TAB}"}" "matched owner=smartwatermelon"

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
printf '* visual\nowner= exempt\n' >"${TMP}/emptyowner.conf"
expect_load_fail "empty owner" "${TMP}/emptyowner.conf" "emptyowner.conf:2"
printf 'owner=a/b exempt\n* visual\n' >"${TMP}/slashowner.conf"
expect_load_fail "owner with slash" "${TMP}/slashowner.conf" "slashowner.conf:1"
printf 'owner=Foo\texempt\n* visual\n' >"${TMP}/owner.conf"
expect_match "owner parses" "${TMP}/owner.conf" "foo/bar" "" "exempt${TAB}1" "${GH}"

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
check "one-arg match" "${o_outcome}${TAB}${o_rule}" "${V}${TAB}10"

echo "passed=${PASS} failed=${FAIL}"
[[ ${FAIL} -eq 0 ]]
