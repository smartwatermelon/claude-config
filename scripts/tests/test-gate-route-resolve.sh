#!/usr/bin/env bash
# Tests for destination and author resolution and the CLI in
# scripts/gate-route.sh (_repo_from_dir, _host_from_dir, _author_for_repo, main).

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
SCRIPT="${ROOT}/scripts/gate-route.sh"
# shellcheck source=/dev/null
source "${SCRIPT}"

TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

# Sandbox: no user git config, no real gh-wrapper state, no repo discovery
# above the scratch tree.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export GATE_RULES_FILE="${ROOT}/gate-rules.conf"
export GH_WRAPPER_LIB="${GH_WRAPPER_LIB:-/Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh}"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
}
check() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: got '$2' want '$3'"; fi; }

TAB=$'\t'

# f12 <line>: first two tab-separated fields.
f12() {
  local rest="${1#*"${TAB}"}"
  printf '%s%s%s' "${1%%"${TAB}"*}" "${TAB}" "${rest%%"${TAB}"*}"
}

# got <cmd...>: run a command, print its output (keeps $() out of check lines).
got() {
  local o
  o="$("$@")" || true
  printf '%s' "${o}"
}

# mkrepo <name> <origin-url|"">
mkrepo() {
  mkdir -p "${TMP}/${1}"
  git -C "${TMP}/${1}" init -q
  [[ -z "$2" ]] || git -C "${TMP}/${1}" remote add origin "$2"
}

# URL spellings all normalize to o/n.
i=0
for url in \
  "git@github.com:Some/Name.git" \
  "https://github.com/some/name" \
  "git@github-beacon:some/name.git" \
  "https://github.com/some/name/" \
  "https://github.com/SOME/Name.git/"; do
  i=$((i + 1))
  mkrepo "url${i}" "${url}"
  val="$(got _repo_from_dir "${TMP}/url${i}")"
  check "url spelling ${url}" "${val}" "some/name"
done

# Host spellings. owner= rules match only when this is exactly github.com.
i=0
while IFS='|' read -r url want; do
  i=$((i + 1))
  mkrepo "host${i}" "${url}"
  val="$(got _host_from_dir "${TMP}/host${i}")"
  check "host of ${url}" "${val}" "${want}"
done <<'URLS'
git@github.com:o/r.git|github.com
https://github.com/o/r|github.com
https://github.com/o/r.git|github.com
ssh://git@github.com/o/r.git|github.com
ssh://git@github.com:22/o/r.git|github.com
git@GitHub.com:o/r.git|github.com
https://user@github.com/o/r|github.com
github.com:o/r.git|github.com
git@gitlab.com:o/r.git|gitlab.com
git@github-beacon:o/r.git|github-beacon
https://github.com.evil.example/o/r|github.com.evil.example
https://github.com@evil.example/o/r|evil.example
file:///srv/git/o/r.git|
/srv/git/o/r.git|
URLS
mkrepo hostnone ""
val="$(got _host_from_dir "${TMP}/hostnone")"
check "host, no origin" "${val}" ""

# CLI cases. run_cli <args...> sets OUT, ERR, RC.
run_cli() {
  OUT="$("${SCRIPT}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}

mkrepo ws "git@github.com:andrewmrich/beacon-workspace.git"
run_cli --dir "${TMP}/ws"
val="$(f12 "${OUT}")"
check "beacon-workspace" "${val}" "visual${TAB}1"
check "beacon-workspace rc/stderr" "${RC}:${ERR}" "0:"

mkrepo bb "git@github-beacon:beacon-biosignals/x.git"
run_cli --dir "${TMP}/bb"
val="$(f12 "${OUT}")"
check "beacon-biosignals" "${val}" "pangram${TAB}2"

mkrepo tm "https://github.com/twistedmelonman/y"
run_cli --dir "${TMP}/tm"
val="$(f12 "${OUT}")"
check "twistedmelonman" "${val}" "visual${TAB}5"

# owner= rules through the CLI. Every github.com spelling of a personal org
# is exempt; forks, third parties and other hosts fall through to visual.
i=0
for url in \
  "git@github.com:smartwatermelon/x.git" \
  "https://github.com/smartwatermelon/x" \
  "https://github.com/SmartWatermelon/x.git" \
  "ssh://git@github.com/smartwatermelon/x.git"; do
  i=$((i + 1))
  mkrepo "swm${i}" "${url}"
  run_cli --dir "${TMP}/swm${i}"
  val="$(f12 "${OUT}")"
  check "owner via ${url}" "${val}" "exempt${TAB}3"
done
mkrepo nos "git@github.com:nightowlstudiollc/site.git"
run_cli --dir "${TMP}/nos"
val="$(f12 "${OUT}")"
check "owner nightowlstudiollc" "${val}" "exempt${TAB}4"
while IFS='|' read -r name url; do
  mkrepo "${name}" "${url}"
  run_cli --dir "${TMP}/${name}"
  val="$(f12 "${OUT}")"
  check "gated: ${url}" "${val}" "visual${TAB}5"
done <<'URLS'
fork|git@github.com:twistedmelonman/Instapaper-MCP.git
third|https://github.com/anthropics/claude-code.git
gitlab|git@gitlab.com:smartwatermelon/x.git
lookalike|https://github.com.evil.example/smartwatermelon/x
userinfo|https://github.com@evil.example/smartwatermelon/x
filepath|file:///srv/smartwatermelon/x.git
URLS

# --repo is gh's owner/name, which names a github.com repository.
run_cli --repo smartwatermelon/x --dir /nonexistent
val="$(f12 "${OUT}")"
check "--repo owner exempt" "${val}" "exempt${TAB}3"
run_cli --repo SmartWatermelon/X
val="$(f12 "${OUT}")"
check "--repo owner mixed case" "${val}" "exempt${TAB}3"
run_cli --repo anthropics/claude-code --dir "${TMP}/swm1"
val="$(f12 "${OUT}")"
check "--repo third party over personal dir" "${val}" "visual${TAB}5"

run_cli --repo beacon-biosignals/x --dir /nonexistent
val="$(f12 "${OUT}")"
check "--repo wins over missing dir" "${val}" "pangram${TAB}2"
run_cli --repo Beacon-Biosignals/X --dir "${TMP}/tm"
val="$(f12 "${OUT}")"
check "--repo wins over remote" "${val}" "pangram${TAB}2"

# Unresolvable repo: rule 3, exit 0, one stderr line per problem.
mkdir -p "${TMP}/plain"
mkrepo noorigin ""
for d in "${TMP}/plain" "${TMP}/noorigin"; do
  run_cli --dir "${d}"
  val="$(f12 "${OUT}")"
  check "unresolved ${d##*/}" "${val}:${RC}" "visual${TAB}5:0"
  if [[ "${ERR}" == *"gate-route: repo unresolved"* ]]; then ok; else bad "unresolved ${d##*/}: stderr '${ERR}'"; fi
done

# No arguments, from a non-repo cwd: both lines once each.
OUT="$(cd "${TMP}/plain" && "${SCRIPT}" 2>"${TMP}/err")"
RC=$?
ERR="$(cat "${TMP}/err")"
val="$(f12 "${OUT}")"
check "no args" "${val}:${RC}" "visual${TAB}5:0"
check "no args stderr" "${ERR}" "gate-route: repo unresolved
gate-route: author unresolved"

# Rules error: exit 4.
GATE_RULES_FILE="${TMP}/missing.conf" run_cli --repo a/b
check "rules error rc" "${RC}" "4"

# Sourcing the wrapper leaves no stray output.
val="$(got _author_for_repo "beacon-biosignals/x" "${TMP}/plain")"
check "author output" "${val}" "andrewmrich"
val="$(got _author_for_repo "smartwatermelon/x" "${TMP}/plain")"
check "author twm" "${val}" "twistedmelonman"
val="$(got _author_for_repo "" "${TMP}/plain")"
check "author empty repo" "${val}" ""

echo "passed=${PASS} failed=${FAIL}"
[[ ${FAIL} -eq 0 ]]
