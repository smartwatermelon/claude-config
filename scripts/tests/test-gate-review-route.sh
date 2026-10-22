#!/usr/bin/env bash
# gate-review.sh: stage and check route by destination (gate-route.sh).
#
# Every gated route is `review` (2026-10-22): no Pangram record, no Pangram line.

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
printf 'repo=acme/pang review\n* review\n' >"${GATE_RULES_FILE}"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
# _stub_personify: a length_check.py that passes everything.
# shellcheck source=/dev/null
source "${GATE_GH%/*}/stub-personify.sh"
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

# review: stages with no record
if (cd "${VIS}" && _cmd_stage --kind commit vtext "${TXT}") >/dev/null 2>&1; then
  _ok "review destination stages with no record"
else
  _no "review destination stages with no record"
fi
VKEY="$(cd "${VIS}" && _batch_key)"
VPEND="${PENDING_ROOT}/${VKEY}"
if cmp -s "${TXT}" "${VPEND}/vtext"; then
  _ok "review item staged byte-identical"
else
  _no "review item staged byte-identical"
fi
want="$(printf 'review\t2\tno rule matched, default')"
sidecar="$(cat "${VPEND}/.route/vtext" 2>/dev/null || true)"
if [[ "${sidecar}" == "${want}" ]]; then
  _ok "stage writes the route sidecar"
else
  _no "stage writes the route sidecar: ${sidecar}"
fi

# A repo's own review rule stages with no record; nothing is written to checks/.
got="$( (cd "${PANG}" && _cmd_stage --kind commit ptext "${TXT}") 2>&1 >/dev/null)"
rc=$?
PKEY="$(cd "${PANG}" && _batch_key)"
if ((rc == 0)) && [[ -f "${PENDING_ROOT}/${PKEY}/ptext" && "${got}" != *Pangram* ]]; then
  _ok "repo review rule stages with no record and no Pangram message"
else
  _no "repo review rule stages with no record and no Pangram message (rc=${rc}): ${got}"
fi
if [[ -z "$(ls -A "${XDG_CONFIG_HOME}/personify/checks")" ]]; then
  _ok "staging writes no check record"
else
  _no "staging writes no check record"
fi

# a restage overwrites a stale sidecar for the name
printf 'exempt\t3\tstale\n' >"${PENDING_ROOT}/${PKEY}/.route/ptext"
(cd "${PANG}" && _cmd_stage --kind commit ptext "${TXT}") >/dev/null 2>&1
first="$(cut -f1,2 "${PENDING_ROOT}/${PKEY}/.route/ptext" || true)"
if [[ "${first}" == "$(printf 'review\t1')" ]]; then
  _ok "restage overwrites a stale sidecar"
else
  _no "restage overwrites a stale sidecar: ${first}"
fi

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

# The review buffer carries no Pangram line: the header has no verdict section.
open_src="$(sed -n '/^_cmd_open()/,/^}/p' "${GATE}" || true)"
if [[ "${open_src}" != *PANGRAM* && "${open_src}" != *_verdict_line* ]]; then
  _ok "open writes no Pangram verdict lines"
else
  _no "open writes no Pangram verdict lines"
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
printf 'repo=beacon-biosignals/x review\nrepo=andrewmrich/beacon-workspace exempt\n* review\n' >"${CHK_RULES}"
CHK_TXT="${TMP}/chk.txt"
printf 'fix(x): approved text for check\n' >"${CHK_TXT}"
rm -f "${APPROVED_ROOT}"/*/* 2>/dev/null || true

_approve_chk() { # approve the fixture bytes under a key
  mkdir -p "${APPROVED_ROOT}/k1"
  cp "${CHK_TXT}" "${APPROVED_ROOT}/k1/chk"
}
_unapprove_chk() { rm -f "${APPROVED_ROOT}/k1/chk"; }
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
_check_case "review rule (Beacon), approved, no record: passes" 0 "" --repo beacon-biosignals/x
_unapprove_chk
_check_case "review rule (Beacon), unapproved: refused" 1 \
  "gate-review: rule 1 (review): no visual approval matches" --repo beacon-biosignals/x
_approve_chk
_check_case "default review rule, approved, no record: passes" 0 "" --repo twistedmelonman/y
_unapprove_chk
_check_case "default review rule, unapproved: refused" 1 \
  "gate-review: rule 3 (review): no visual approval matches" --repo twistedmelonman/y
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
_check_case "no flags, unapproved: refused as review" 1 "rule 3 (review): no visual approval matches"
# --dir routes by the checkout's origin
_mkrepo "${TMP}/bb" beacon-biosignals/x
_check_case "--dir routes by origin (review, unapproved)" 1 "rule 1 (review): no visual approval matches" --dir "${TMP}/bb"
_approve_chk
_check_case "--dir routes by origin (review, approved, no record)" 0 "" --dir "${TMP}/bb"
# broken rules file
printf 'repo=a/b bogus\n' >"${TMP}/bad-rules.conf"
out="$(GATE_RULES_FILE="${TMP}/bad-rules.conf" _cmd_check "${CHK_TXT}" --repo a/b 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"bad-rules.conf:1"* ]]; then
  _ok "broken rules file: exit 1 naming the file and line"
else
  _no "broken rules file: exit 1 naming the file and line (rc=${rc}): ${out}"
fi
# A rules file still using a retired outcome fails closed: check refuses.
printf '* pangram\n' >"${TMP}/old-rules.conf"
out="$(GATE_RULES_FILE="${TMP}/old-rules.conf" _cmd_check "${CHK_TXT}" --repo a/b 2>&1 >/dev/null)"
rc=$?
if ((rc == 1)) && [[ "${out}" == *"unknown outcome 'pangram'"* ]]; then
  _ok "retired pangram outcome: check refuses even approved text"
else
  _no "retired pangram outcome: check refuses even approved text (rc=${rc}): ${out}"
fi
# copy is always review: approved passes with no record, unapproved refuses.
_check_case "copy kind, approved, no record: passes" 0 "" --kind copy --dir "${TMP}/bb"
_unapprove_chk
_check_case "copy kind, unapproved: refused as review" 1 "rule copy (review): no visual approval matches" --kind copy --dir "${TMP}/bb"
out="$(_cmd_route --kind copy)"
if [[ "${out}" == "$(printf 'review\tcopy\tpublic-facing copy (copy-paths.conf)')" ]]; then
  _ok "route --kind copy prints review"
else
  _no "route --kind copy prints review: ${out}"
fi
out="$(_cmd_route)"
if [[ "${out}" == "$(printf 'review\t3\tdestination unresolved')" ]]; then
  _ok "route with no destination prints review / rule 3"
else
  _no "route with no destination prints review / rule 3: ${out}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
