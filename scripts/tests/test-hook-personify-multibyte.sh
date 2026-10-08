#!/usr/bin/env bash
# hook-block-personify.sh: a command holding 3- or 4-byte UTF-8 characters
# (✗, an emoji) is parsed, not blocked. macOS /usr/bin/awk (version 20200816)
# counts bytes but, in a UTF-8 locale, its regex match decodes characters, so
# the character-by-character scanners handed it half a character and died with
# "towc: multibyte conversion failure". The hook then exited 2 and blocked
# every such command. Run under a UTF-8 locale on purpose: under C the bug
# does not show.

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

# Same sandbox as test-hook-personify-route.sh: no user git config, no real
# gate dir, no real check records.
export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
mkdir -p "${XDG_CONFIG_HOME}/personify/checks"
export GATE_REVIEW_DIR="${TMP}/gate"
# Fork lookups (gate-route _is_fork) go to a stub, never to GitHub.
GATE_GH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/gh-fork-stub.sh"
export GATE_GH
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf '* visual\n' >"${GATE_RULES_FILE}"

# The failure needs a UTF-8 locale. Linux CI images often name it C.UTF-8.
# Read the list once: `locale -a | grep -q` under pipefail fails when grep
# exits early and locale takes SIGPIPE.
UTF8=""
locales="$(locale -a 2>/dev/null)"
for l in en_US.UTF-8 C.UTF-8 C.utf8 en_US.utf8; do
  if grep -qix "${l}" <<<"${locales}"; then
    UTF8="${l}"
    break
  fi
done
if [[ -z "${UTF8}" ]]; then
  echo "SKIP: no UTF-8 locale installed, so the failure cannot be reproduced"
  exit 0
fi
export LC_ALL="${UTF8}"

REPO="${TMP}/repo"
mkdir -p "${REPO}"
git -C "${REPO}" init -q

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

# _case <label> <want-rc> <want-substring> <command>
_case() {
  local label="$1" wrc="$2" wsub="$3" json err rc
  json="$(jq -n --arg c "$4" --arg d "${REPO}" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* && "${err}" != *towc* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}

echo "locale: ${LC_ALL}"
_case "3-byte character in an ungated command passes" 0 "" 'echo "a✗b"'
_case "4-byte emoji in an ungated command passes" 0 "" 'echo "🛑 done"'
_case "2-byte character inside double quotes passes" 0 "" 'echo "café"'
_case "multibyte inside single quotes passes" 0 "" "echo 'a✗;b'"
_case "multibyte inside dollar quotes passes" 0 "" "echo \$'a✗b'"
_case "multibyte before a line continuation passes" 0 "" $'echo "✗" \\\n  && ls'
_case "multibyte next to a quoted separator passes" 0 "" 'echo "✗; ✓" && ls'
_case "multibyte in a heredoc body passes" 0 "" $'cat <<EOF\n✗ 🛑\nEOF'
# The gate still reads the command: an inline message is still refused, for
# the gate's own reason. This one is refused before _quoted_segments runs, so
# it passed before the fix too; it guards the gate, not the crash.
_case "gated commit with multibyte -m still blocks" 2 "text given inline" \
  "git -C ${REPO} commit -m \"✗ fix\""

echo ""
echo "passed: ${pass}  failed: ${fail}"
((fail == 0))
