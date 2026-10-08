#!/usr/bin/env bash
# hook-block-personify.sh routes before form checks (#698): exempt text passes in any form; gated text does not.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
[[ -x "${HOOK}" ]] || {
  echo "cannot find hook at ${HOOK}" >&2
  exit 1
}
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

# Sandbox, as in test-hook-personify-route.sh.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
# No gh wrapper: the author is unresolved, and these rules need none.
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"
export GATE_RULES_FILE="${TMP}/rules.conf"
cat >"${GATE_RULES_FILE}" <<'RULES'
owner=smartwatermelon exempt
* visual
RULES

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

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
EXEMPT="${TMP}/exempt"
GATED="${TMP}/gated"
_mkrepo "${EXEMPT}" smartwatermelon/z
_mkrepo "${GATED}" someone-else/y
printf 'msg\n' >"${EXEMPT}/msg.txt"

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

# --- exempt destination: every form passes, and nothing asks for approval ---
_case "exempt: git commit -F - passes" 0 "" "${EXEMPT}" \
  "git commit -F -"
_case "exempt: heredoc on stdin passes" 0 "" "${EXEMPT}" \
  "git commit -F - <<'EOF'
fix(x): a message
EOF"
_case "exempt: git commit -m passes" 0 "" "${EXEMPT}" \
  "git commit -m 'fix(x): inline'"
_case "exempt: relative -F path passes" 0 "" "${EXEMPT}" \
  "git commit -F msg.txt"
_case "exempt via git -C from a gated cwd passes" 0 "" "${GATED}" \
  "git -C ${EXEMPT} commit -F -"
_case "exempt: --body-file with a variable path passes" 0 "" "${EXEMPT}" \
  "gh issue comment 1 --body-file \$S/c.md"
_case "exempt: inline gh --body passes" 0 "" "${EXEMPT}" \
  "gh pr create --title t --body 'inline'"
_case "exempt -R from a gated cwd passes" 0 "" "${GATED}" \
  "gh pr create -R smartwatermelon/z --title t --body 'inline'"
_case "exempt gh api repos/ path, inline -f body passes" 0 "" "${GATED}" \
  "gh api repos/smartwatermelon/z/issues/1/comments -f body=inline"

# --- gated destination: the form checks still run ---------------------------
_case "gated: git commit -F - blocks as not absolute" 2 "is not absolute" "${GATED}" \
  "git commit -F -"
_case "gated: git commit -m blocks as inline" 2 "text given inline" "${GATED}" \
  "git commit -m 'fix(x): inline'"
_case "gated via git -C from an exempt cwd blocks" 2 "is not absolute" "${EXEMPT}" \
  "git -C ${GATED} commit -F -"
_case "gated: inline gh --body blocks" 2 "text given inline" "${GATED}" \
  "gh pr create --title t --body 'inline'"
_case "gated -R from an exempt cwd blocks" 2 "text given inline" "${EXEMPT}" \
  "gh pr create -R someone-else/y --title t --body 'inline'"
# A URL with no -R may be a flag value, so the gated checkout must pass too.
_case "exempt URL, gated checkout: blocks" 2 "text given inline" "${GATED}" \
  "gh pr comment https://github.com/smartwatermelon/z/pull/1 --body 'inline'"

# --- destinations that cannot be routed never count as exempt --------------
_case "graphql body in an exempt cwd blocks" 2 "GraphQL mutation" "${EXEMPT}" \
  "gh api graphql -f query='mutation { addComment(input: {subjectId: \"x\", body: \"hi\"}) { clientMutationId } }'"
_case "unresolvable cd blocks" 2 "cd the hook cannot resolve" "${EXEMPT}" \
  "cd \$X && git commit -m x"

# A broken rules file is a router failure, not an exemption.
printf 'not-a-rule\n' >"${GATE_RULES_FILE}"
_case "router error: exempt repo falls back to the full checks" 2 "is not absolute" "${EXEMPT}" \
  "git commit -F -"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
