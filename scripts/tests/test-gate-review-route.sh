#!/usr/bin/env bash
# gate-review.sh: stage routes by destination (gate-route.sh) and shows a banner.
#
# A `visual` destination stages without a Pangram record and the review buffer
# says so; a `pangram` destination still refuses. The banner is a header line,
# so it must never reach the approved bytes or the hash.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
export GH_WRAPPER_LIB="${GH_WRAPPER_LIB:-/Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh}"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'repo=acme/pang pangram\n* visual\n' >"${GATE_RULES_FILE}"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
# A stub length_check.py that passes everything: CI has no personify checkout, and test-*-length.sh use the real one.
_stub_personify() { # <config dir> <install dir>
  mkdir -p "$1/plugins" "$2/scripts"
  : >"$2/scripts/pangram_check.py"
  printf 'import sys\nsys.exit(0)\n' >"$2/scripts/length_check.py"
  jq -n --arg p "$2" '{plugins:{"personify@personify":[{installPath:$p}]}}' >"$1/plugins/installed_plugins.json"
}
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
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
_mkrepo "${VIS}" acme/other
_mkrepo "${PANG}" acme/pang

TXT="${TMP}/text.txt"
printf 'fix(x): a visual-only text\n' >"${TXT}"

# visual: stages with no record
if (cd "${VIS}" && _cmd_stage --kind commit vtext "${TXT}") >/dev/null 2>&1; then
  _ok "visual destination stages with no record"
else
  _no "visual destination stages with no record"
fi
VKEY="$(cd "${VIS}" && _batch_key)"
VPEND="${PENDING_ROOT}/${VKEY}"
if cmp -s "${TXT}" "${VPEND}/vtext"; then
  _ok "visual item staged byte-identical"
else
  _no "visual item staged byte-identical"
fi
want="$(printf 'visual\t2\tno rule matched, default')"
sidecar="$(cat "${VPEND}/.route/vtext" 2>/dev/null || true)"
if [[ "${sidecar}" == "${want}" ]]; then
  _ok "stage writes the route sidecar"
else
  _no "stage writes the route sidecar: ${sidecar}"
fi

# pangram: still refuses with today's message
got="$( (cd "${PANG}" && _cmd_stage --kind commit ptext "${TXT}") 2>&1 >/dev/null)"
rc=$?
if ((rc != 0)) && [[ "${got}" == *"no Pangram check record for ${TXT}"* ]]; then
  _ok "pangram destination without a record refuses"
else
  _no "pangram destination without a record refuses (rc=${rc}): ${got}"
fi
PKEY="$(cd "${PANG}" && _batch_key)"
if [[ ! -e "${PENDING_ROOT}/${PKEY}/ptext" ]]; then
  _ok "refused pangram stage leaves nothing pending"
else
  _no "refused pangram stage leaves nothing pending"
fi

# a pangram stage with a record removes a stale visual sidecar for the name
sha="$(sha256sum "${TXT}" | cut -d' ' -f1)"
printf '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":120}\n' \
  >"${XDG_CONFIG_HOME}/personify/checks/${sha}.json"
mkdir -p "${PENDING_ROOT}/${PKEY}/.route"
printf 'visual\t3\tstale\n' >"${PENDING_ROOT}/${PKEY}/.route/ptext"
(cd "${PANG}" && _cmd_stage --kind commit ptext "${TXT}") >/dev/null 2>&1
first="$(cut -f1 "${PENDING_ROOT}/${PKEY}/.route/ptext" || true)"
if [[ "${first}" == "pangram" ]]; then
  _ok "restage overwrites a stale sidecar"
else
  _no "restage overwrites a stale sidecar"
fi
rm -f "${XDG_CONFIG_HOME}/personify/checks/${sha}.json"

# router error: stage exits 1 with the router's message
mv "${GATE_RULES_FILE}" "${GATE_RULES_FILE}.bak"
got="$( (cd "${VIS}" && _cmd_stage --kind commit rerr "${TXT}") 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${got}" == *"rules file not found"* ]] && [[ ! -e "${VPEND}/rerr" ]]; then
  _ok "router error makes stage exit 1 with its message"
else
  _no "router error makes stage exit 1 with its message (rc=${rc}): ${got}"
fi
mv "${GATE_RULES_FILE}.bak" "${GATE_RULES_FILE}"

# banner in the header line
got="$(_verdict_line vtext "${VPEND}/vtext")"
if [[ "${got}" == "# vtext: NOT PANGRAM REVIEWED (rule 2: no rule matched, default)" ]]; then
  _ok "verdict line carries the banner for a visual item"
else
  _no "verdict line carries the banner for a visual item: ${got}"
fi
# a record wins over a visual sidecar
printf '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":120}\n' \
  >"${XDG_CONFIG_HOME}/personify/checks/$(sha256sum "${TXT}" | cut -d' ' -f1).json"
got="$(_verdict_line vtext "${VPEND}/vtext")"
if [[ "${got}" == "# vtext: PASS (Human, fraction_ai 0.0, 120 words)" ]]; then
  _ok "a check record takes precedence over the banner"
else
  _no "a check record takes precedence over the banner: ${got}"
fi
rm -f "${XDG_CONFIG_HOME}"/personify/checks/*.json
# no sidecar, no record: unchanged
touch "${TMP}/nosidecar"
got="$(_verdict_line nosidecar "${TMP}/nosidecar")"
if [[ "${got}" == "# nosidecar: NO RECORD" ]]; then
  _ok "no sidecar and no record still says NO RECORD"
else
  _no "no sidecar and no record still says NO RECORD: ${got}"
fi

# the sidecar is not an artifact
listed=0
for f in "${VPEND}"/*; do [[ -e "${f}" ]] && listed=$((listed + 1)); done
if ((listed == 1)); then
  _ok "the sidecar directory is not globbed as an artifact"
else
  _no "the sidecar directory is not globbed as an artifact (${listed} entries)"
fi
open_body="$(sed -n '/^_cmd_open()/,/^}/p' "${GATE}" || true)"
if [[ "${open_body}" == *"-maxdepth 1 -type f"* ]]; then
  _ok "open counts only top-level items, not the sidecar"
else
  _no "open counts only top-level items, not the sidecar"
fi

# approval: bytes and hash equal the staged text, sidecar removed
BODY="$(cat "${TXT}")"
BODY="${BODY}"$'\n'
(cd "${VIS}" && _use_key && _write_approved vtext "${BODY}")
if cmp -s "${TXT}" "${APPROVED_ROOT}/${VKEY}/vtext" &&
  [[ "$(_hash "${APPROVED_ROOT}/${VKEY}/vtext" || true)" == "$(_hash "${TXT}" || true)" ]]; then
  _ok "approved bytes and hash equal the staged text (no banner)"
else
  _no "approved bytes and hash equal the staged text (no banner)"
fi
if [[ ! -e "${VPEND}/vtext" && ! -e "${VPEND}/.route/vtext" ]]; then
  _ok "approval removes the pending item and its sidecar"
else
  _no "approval removes the pending item and its sidecar"
fi

# a dropped (emptied) item leaves the pending item, so its sidecar stays too;
# a restage after an approval writes a fresh sidecar
(cd "${VIS}" && _cmd_stage --kind commit vtext "${TXT}") >/dev/null 2>&1
if [[ -f "${VPEND}/.route/vtext" ]]; then
  _ok "restage after approval writes a fresh sidecar"
else
  _no "restage after approval writes a fresh sidecar"
fi
(cd "${VIS}" && _use_key && _write_approved vtext "")
if [[ -f "${VPEND}/vtext" && -f "${VPEND}/.route/vtext" ]]; then
  _ok "an emptied item stays pending with its sidecar (nothing removed)"
else
  _no "an emptied item stays pending with its sidecar (nothing removed)"
fi
# the pending-removal helper drops both
_remove_pending "${VPEND}" vtext
if [[ ! -e "${VPEND}/vtext" && ! -e "${VPEND}/.route/vtext" ]]; then
  _ok "_remove_pending deletes the item and its sidecar"
else
  _no "_remove_pending deletes the item and its sidecar"
fi

# --- check: route-aware -------------------------------------------------------
CHK_RULES="${TMP}/check-rules.conf"
printf 'repo=beacon-biosignals/x pangram\nrepo=andrewmrich/beacon-workspace exempt\n* visual\n' >"${CHK_RULES}"
CHK_TXT="${TMP}/chk.txt"
printf 'fix(x): approved text for check\n' >"${CHK_TXT}"
CHK_SHA="$(_raw_sha "${CHK_TXT}")"
CHK_REC="${XDG_CONFIG_HOME}/personify/checks/${CHK_SHA}.json"
rm -f "${APPROVED_ROOT}"/*/* 2>/dev/null || true

_approve_chk() { # approve the fixture bytes under a key
  mkdir -p "${APPROVED_ROOT}/k1"
  cp "${CHK_TXT}" "${APPROVED_ROOT}/k1/chk"
}
_unapprove_chk() { rm -f "${APPROVED_ROOT}/k1/chk"; }
_rec() { printf '{"status":"%s","verdict":"%s","fraction_ai":0.0,"word_count":120}\n' "$1" "$2" >"${CHK_REC}"; }
# GATE_RULES_FILE is already exported at the top of this file, so the inline
# override below reaches the router subprocess.
_check_case() { # <label> <want-rc> <want-substring-or-empty> <args...>
  local label="$1" wrc="$2" wsub="$3" out rc
  shift 3
  out="$(GATE_RULES_FILE="${CHK_RULES}" _cmd_check "${CHK_TXT}" "$@" 2>&1 >/dev/null)"
  rc=$?
  if ((rc == wrc)) && [[ "${out}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${out}"
  fi
}

_approve_chk
_check_case "pangram rule, approved, no record: refused, no check ran" 1 \
  "gate-review: rule 1 (pangram): no Pangram check ran on these bytes" --repo beacon-biosignals/x
_rec FAIL AI
_check_case "pangram rule, approved, FAIL record: passes" 0 "" --repo beacon-biosignals/x
_unapprove_chk
_check_case "pangram rule, record but unapproved: verdict recorded line" 1 \
  "gate-review: rule 1 (pangram): verdict AI recorded; no visual approval matches" --repo beacon-biosignals/x
rm -f "${CHK_REC}"
_check_case "pangram rule, unapproved, no record: no check ran" 1 \
  "rule 1 (pangram): no Pangram check ran on these bytes" --repo beacon-biosignals/x
_approve_chk
_check_case "visual rule, approved, no record: passes" 0 "" --repo twistedmelonman/y
_unapprove_chk
_check_case "visual rule, unapproved: refused" 1 \
  "gate-review: rule 3 (visual): no visual approval matches" --repo twistedmelonman/y
_approve_chk
_check_case "beacon-workspace (exempt), approved, no record: passes" 0 "" --repo andrewmrich/beacon-workspace
_unapprove_chk
_check_case "exempt skips the approval too" 0 "" --repo andrewmrich/beacon-workspace
_approve_chk
_check_case "no flags, approved: passes silently" 0 ""
# no flags: the caller's cwd must not pick the route
out="$(cd "${PANG}" && GATE_RULES_FILE="${CHK_RULES}" _cmd_check "${CHK_TXT}" 2>&1)"
rc=$?
if ((rc == 0)) && [[ -z "${out}" ]]; then
  _ok "no flags: cwd is ignored and stderr is quiet"
else
  _no "no flags: cwd is ignored and stderr is quiet (rc=${rc}): ${out}"
fi
_unapprove_chk
_check_case "no flags, unapproved: refused as visual" 1 "(visual): no visual approval matches"
_approve_chk
# --dir routes by the checkout's origin
_mkrepo "${TMP}/bb" beacon-biosignals/x
_check_case "--dir routes by origin (pangram, no record)" 1 "no Pangram check ran" --dir "${TMP}/bb"
# broken rules file
printf 'repo=a/b bogus\n' >"${TMP}/bad-rules.conf"
out="$(GATE_RULES_FILE="${TMP}/bad-rules.conf" _cmd_check "${CHK_TXT}" --repo a/b 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"bad-rules.conf:1"* ]]; then
  _ok "broken rules file: exit 1 naming the file and line"
else
  _no "broken rules file: exit 1 naming the file and line (rc=${rc}): ${out}"
fi
rm -f "${CHK_REC}"
_unapprove_chk

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
