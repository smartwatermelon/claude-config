#!/usr/bin/env bash
# End to end: stage -> approve -> hook, across the destinations the shipped
# gate-rules.conf routes differently.
#
#   Exempt: beacon-workspace, smartwatermelon, twistedmelonman. Pangram: beacon. Visual: third parties.
#
# GATE_RULES_FILE points at the repo's real gate-rules.conf, so an edit that
# changes the routing fails here. The check-records directory is a sandbox:
# Pangram is never called.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${HERE}/.." && pwd)"
GATE="${SCRIPTS}/gate-review.sh"
HOOK="${SCRIPTS}/hook-block-personify.sh"
for f in "${GATE}" "${HOOK}"; do
  [[ -f "${f}" ]] || {
    echo "cannot find ${f}" >&2
    exit 1
  }
done
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

# Sandbox: no user git config, no repo discovery above the scratch tree, a
# temp gate dir (so the real SUSPENDED file cannot apply), no real records.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GH_WRAPPER_LIB="${GH_WRAPPER_LIB:-/Users/andrewrich/Developer/dotfiles/bash/gh-wrapper.sh}"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
# A stub length_check.py that passes everything: CI has no personify checkout, and test-*-length.sh use the real one.
_stub_personify() { # <config dir> <install dir>
  mkdir -p "$1/plugins" "$2/scripts"
  : >"$2/scripts/pangram_check.py"
  printf 'import sys\nsys.exit(0)\n' >"$2/scripts/length_check.py"
  jq -n --arg p "$2" '{plugins:{"personify@personify":[{installPath:$p}]}}' >"$1/plugins/installed_plugins.json"
}
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
_stub_personify "${CLAUDE_CONFIG_DIR}" "${TMP}/personify"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
export GATE_RULES_FILE="${GATE_RULES_FILE:-$(cd "${SCRIPTS}/.." && pwd)/gate-rules.conf}"
[[ -f "${GATE_RULES_FILE}" ]] || {
  echo "cannot find rules file ${GATE_RULES_FILE}" >&2
  exit 1
}

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
  ROUTE_SCRIPT="${SCRIPTS}/gate-route.sh"
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
WORKSPACE="${TMP}/workspace"
EMPLOYER="${TMP}/employer"
PERSONAL="${TMP}/personal"
_mkrepo "${WORKSPACE}" andrewmrich/beacon-workspace
_mkrepo "${EMPLOYER}" beacon-biosignals/x
_mkrepo "${PERSONAL}" twistedmelonman/y
VISUAL="${TMP}/visual"
_mkrepo "${VISUAL}" someone-else/y

_rec_for() {
  local sha
  sha="$(sha256sum "$1" | cut -d' ' -f1)"
  printf '{"status":"PASS","verdict":"Human","fraction_ai":0.0,"word_count":120}\n' \
    >"${XDG_CONFIG_HOME}/personify/checks/${sha}.json"
}

# _approve <repo> <name>: stage ${TMP}/<name>.txt from inside <repo>, capture
# the review header line, approve the way a reviewer's saved buffer does
# (_split_batch), and leave the approved file's path in ${TMP}/<name>.path.
_approve() {
  local repo="$1" name="$2"
  (
    cd "${repo}" || exit 1
    _cmd_stage --kind commit "${name}" "${TMP}/${name}.txt" >/dev/null || exit 1
    _use_key
    _verdict_line "${name}" "${PENDING}/${name}" >"${TMP}/${name}.line"
    {
      printf '# STATUS: APPROVED\n# BATCH: e2e-%s\n\n' "${name}"
      printf '=== %s ===\n' "${name}"
      cat "${PENDING}/${name}"
    } >"${TMP}/${name}.buf"
    _split_batch "${TMP}/${name}.buf" "e2e-${name}" >/dev/null || exit 1
    printf '%s\n' "${APPROVED}/${name}" >"${TMP}/${name}.path"
  )
}

# _hook <cwd> <command>: run the hook the way Claude Code does; sets rc, err.
_hook() {
  local json
  json="$(jq -n --arg c "$2" --arg d "$1" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
}

# --- workspace and personal: exempt (2026-10-08) ---------------------------
printf 'docs: workspace note nobody approved\n' >"${TMP}/ws.txt"
_hook "${WORKSPACE}" "git -C ${WORKSPACE} commit -F ${TMP}/ws.txt"
if ((rc == 0)); then
  _ok "workspace: commit passes unapproved"
else
  _no "workspace: commit passes unapproved (rc=${rc}): ${err}"
fi
_hook "${PERSONAL}" "git -C ${PERSONAL} commit -F ${TMP}/ws.txt"
if ((rc == 0)); then
  _ok "twistedmelonman: commit passes unapproved"
else
  _no "twistedmelonman: commit passes unapproved (rc=${rc}): ${err}"
fi

# --- visual destination: rule 13 --------------------------------------------
printf 'fix(y): third-party change\n' >"${TMP}/pers.txt"
if _approve "${VISUAL}" pers; then
  _ok "visual: stage and approve without a record"
else
  _no "visual: stage and approve without a record"
fi
line="$(cat "${TMP}/pers.line" 2>/dev/null || true)"
if [[ "${line}" == "# pers: NOT PANGRAM REVIEWED (rule 13: "* ]]; then
  _ok "visual: review shows the rule 13 banner"
else
  _no "visual: review shows the rule 13 banner: ${line}"
fi
PERS_APPROVED="$(cat "${TMP}/pers.path" 2>/dev/null || true)"
_hook "${VISUAL}" "git -C ${VISUAL} commit -F ${PERS_APPROVED}"
if ((rc == 0)); then
  _ok "visual: hook passes with no record"
else
  _no "visual: hook passes with no record (rc=${rc}): ${err}"
fi

# --- employer: rule 9, pangram ---------------------------------------------
printf 'fix(x): employer change\n' >"${TMP}/emp.txt"
if (cd "${EMPLOYER}" && _cmd_stage --kind commit emp "${TMP}/emp.txt") >/dev/null 2>&1; then
  _no "employer: stage refuses without a record"
else
  _ok "employer: stage refuses without a record"
fi
_rec_for "${TMP}/emp.txt"
if _approve "${EMPLOYER}" emp; then
  _ok "employer: stage and approve once a record exists"
else
  _no "employer: stage and approve once a record exists"
fi
line="$(cat "${TMP}/emp.line" 2>/dev/null || true)"
if [[ "${line}" == "# emp: PASS (Human, "* ]]; then
  _ok "employer: review shows the record, not a banner"
else
  _no "employer: review shows the record, not a banner: ${line}"
fi
EMP_APPROVED="$(cat "${TMP}/emp.path" 2>/dev/null || true)"
# The record is keyed on the exact approved bytes; remove it to prove the block.
SHA="$(sha256sum "${EMP_APPROVED}" | cut -d' ' -f1)"
REC="${XDG_CONFIG_HOME}/personify/checks/${SHA}.json"
mv "${REC}" "${REC}.hold"
_hook "${EMPLOYER}" "git -C ${EMPLOYER} commit -F ${EMP_APPROVED}"
if ((rc == 2)) && [[ "${err}" == *"no Pangram check ran"* ]]; then
  _ok "employer: hook blocks with no record"
else
  _no "employer: hook blocks with no record (rc=${rc}): ${err}"
fi
mv "${REC}.hold" "${REC}"
_hook "${EMPLOYER}" "git -C ${EMPLOYER} commit -F ${EMP_APPROVED}"
if ((rc == 0)); then
  _ok "employer: hook passes once the record exists"
else
  _no "employer: hook passes once the record exists (rc=${rc}): ${err}"
fi

# --- owner= rules: personal org exempt, third party still gated -------------
# The text is never staged or approved: an exempt destination must pass it
# unmeasured, and every other destination must block it.
ORG="${TMP}/org"
THIRD="${TMP}/third"
NOWHERE="${TMP}/nowhere"
_mkrepo "${ORG}" smartwatermelon/z
_mkrepo "${THIRD}" anthropics/claude-code
mkdir -p "${NOWHERE}"
UNAPPROVED="${TMP}/unapproved.txt"
printf 'fix(z): text nobody approved\n' >"${UNAPPROVED}"

_hook "${ORG}" "git -C ${ORG} commit -F ${UNAPPROVED}"
if ((rc == 0)); then
  _ok "org: commit passes unapproved"
else
  _no "org: commit passes unapproved (rc=${rc}): ${err}"
fi
_hook "${ORG}" "gh pr create --title t --body-file ${UNAPPROVED}"
if ((rc == 0)); then
  _ok "org: PR from the checkout passes unapproved"
else
  _no "org: PR from the checkout passes unapproved (rc=${rc}): ${err}"
fi
_hook "${NOWHERE}" "gh pr create --title t --body-file ${UNAPPROVED} -R smartwatermelon/z"
if ((rc == 0)); then
  _ok "org: PR with -R passes unapproved"
else
  _no "org: PR with -R passes unapproved (rc=${rc}): ${err}"
fi
_hook "${THIRD}" "git -C ${THIRD} commit -F ${UNAPPROVED}"
if ((rc == 2)); then
  _ok "third party: commit blocks unapproved"
else
  _no "third party: commit blocks unapproved (rc=${rc}): ${err}"
fi
_hook "${THIRD}" "gh pr create --title t --body-file ${UNAPPROVED}"
if ((rc == 2)); then
  _ok "third party: PR from the checkout blocks unapproved"
else
  _no "third party: PR from the checkout blocks unapproved (rc=${rc}): ${err}"
fi
_hook "${ORG}" "gh pr create --title t --body-file ${UNAPPROVED} -R anthropics/claude-code"
if ((rc == 2)); then
  _ok "third party: PR with -R from an org checkout blocks unapproved"
else
  _no "third party: PR with -R from an org checkout blocks unapproved (rc=${rc}): ${err}"
fi
_hook "${VISUAL}" "git -C ${VISUAL} commit -F ${UNAPPROVED}"
if ((rc == 2)); then
  _ok "visual: commit blocks unapproved"
else
  _no "visual: commit blocks unapproved (rc=${rc}): ${err}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
