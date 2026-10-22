#!/usr/bin/env bash
# End to end: stage -> approve -> hook, across the destinations the shipped
# gate-rules.conf routes differently.
#
#   Exempt: beacon-workspace, personal owners, NOS, private andrewmrich.
#   Review: beacon, public andrewmrich, third parties.
#
# GATE_RULES_FILE points at the repo's real gate-rules.conf, so an edit that
# changes the routing fails here. No route needs a Pangram check record
# (2026-10-22), and none is ever written.

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
# Copy gate off: these suites do not test it (copy-paths-none.conf says why).
export COPY_PATHS_FILE="${GATE_GH%/*}/copy-paths-none.conf"
# _stub_personify: a length_check.py that passes everything.
# shellcheck source=/dev/null
source "${GATE_GH%/*}/stub-personify.sh"
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

# _approve <repo> <name>: stage and approve ${TMP}/<name>.txt from <repo>;
# the approved path goes to ${TMP}/<name>.path.
_approve() {
  local repo="$1" name="$2"
  (
    cd "${repo}" || exit 1
    _cmd_stage --kind commit "${name}" "${TMP}/${name}.txt" >/dev/null || exit 1
    _use_key
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

# --- third-party destination: rule 11, review --------------------------------
printf 'fix(y): third-party change\n' >"${TMP}/pers.txt"
if _approve "${VISUAL}" pers; then
  _ok "third party: stage and approve without a record"
else
  _no "third party: stage and approve without a record"
fi
PERS_APPROVED="$(cat "${TMP}/pers.path" 2>/dev/null || true)"
_hook "${VISUAL}" "git -C ${VISUAL} commit -F ${PERS_APPROVED}"
if ((rc == 0)); then
  _ok "third party: hook passes approved text with no record"
else
  _no "third party: hook passes approved text with no record (rc=${rc}): ${err}"
fi

# --- employer: review, no Pangram record --------------------------------------
printf 'fix(x): employer change\n' >"${TMP}/emp.txt"
_hook "${EMPLOYER}" "git -C ${EMPLOYER} commit -F ${TMP}/emp.txt"
if ((rc == 2)) && [[ "${err}" == *"(review): no visual approval matches"* && "${err}" != *Pangram* ]]; then
  _ok "employer: hook blocks unapproved text as review, naming no Pangram step"
else
  _no "employer: hook blocks unapproved text as review, naming no Pangram step (rc=${rc}): ${err}"
fi
if _approve "${EMPLOYER}" emp; then
  _ok "employer: stage and approve with no record"
else
  _no "employer: stage and approve with no record"
fi
EMP_APPROVED="$(cat "${TMP}/emp.path" 2>/dev/null || true)"
_hook "${EMPLOYER}" "git -C ${EMPLOYER} commit -F ${EMP_APPROVED}"
if ((rc == 0)); then
  _ok "employer: hook passes approved text with no record"
else
  _no "employer: hook passes approved text with no record (rc=${rc}): ${err}"
fi
if [[ -z "$(ls -A "${XDG_CONFIG_HOME}/personify/checks")" ]]; then
  _ok "no check record was written"
else
  _no "no check record was written"
fi

# --- andrewmrich: exempt if private, else review ---
# (Andrew, 2026-10-22.) The stub answers GitHub's private field.
export GATE_TEST_PRIVATE="andrewmrich/notes"
export GATE_TEST_GH_FAIL="andrewmrich/offline"
AM_PRIV="${TMP}/am-priv"
AM_PUB="${TMP}/am-pub"
AM_DOWN="${TMP}/am-down"
_mkrepo "${AM_PRIV}" andrewmrich/notes
_mkrepo "${AM_PUB}" andrewmrich/site
_mkrepo "${AM_DOWN}" andrewmrich/offline
printf 'docs: a note nobody approved\n' >"${TMP}/am.txt"
_hook "${AM_PRIV}" "git -C ${AM_PRIV} commit -F ${TMP}/am.txt"
if ((rc == 0)); then
  _ok "private andrewmrich repo: commit passes unapproved"
else
  _no "private andrewmrich repo: commit passes unapproved (rc=${rc}): ${err}"
fi
_hook "${AM_PRIV}" "gh pr create --title t --body-file ${TMP}/am.txt -R andrewmrich/notes"
if ((rc == 0)); then
  _ok "private andrewmrich repo: PR with -R passes unapproved"
else
  _no "private andrewmrich repo: PR with -R passes unapproved (rc=${rc}): ${err}"
fi
_hook "${AM_PUB}" "git -C ${AM_PUB} commit -F ${TMP}/am.txt"
if ((rc == 2)) && [[ "${err}" == *"(review)"* ]]; then
  _ok "public andrewmrich repo: commit blocks unapproved"
else
  _no "public andrewmrich repo: commit blocks unapproved (rc=${rc}): ${err}"
fi
_hook "${AM_DOWN}" "git -C ${AM_DOWN} commit -F ${TMP}/am.txt"
if ((rc == 2)) && [[ "${err}" == *"(review)"* ]]; then
  _ok "andrewmrich lookup fails: commit blocks unapproved"
else
  _no "andrewmrich lookup fails: commit blocks unapproved (rc=${rc}): ${err}"
fi
unset GATE_TEST_PRIVATE GATE_TEST_GH_FAIL

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
  _ok "third party (someone-else): commit blocks unapproved"
else
  _no "third party (someone-else): commit blocks unapproved (rc=${rc}): ${err}"
fi

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
