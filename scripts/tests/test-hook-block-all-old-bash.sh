#!/usr/bin/env bash
# Tests for hook-block-all.sh's bash-version guard
#
# Claude Code runs the hook as `env bash`, so the interpreter is whatever bash
# is first on the PATH it was launched with. Without Homebrew on that PATH it
# is macOS /bin/bash 3.2, and hook-block-git-worktree.sh died on `mapfile`
# (exit 127) for every command. These tests put a `bash` that points to
# /bin/bash first on PATH and check that the chain still runs and still blocks.
#
# Needs a bash 3.x at /bin/bash and a bash 4+ the guard can find. Where either
# is missing (Linux CI has bash 5 at /bin/bash), the test skips.

set -uo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPT_DIR}/hook-block-all.sh"

old_major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 0)"
if [[ "${old_major}" -ge 4 || "${old_major}" -eq 0 ]]; then
  echo "SKIP: /bin/bash is not bash 3.x"
  exit 0
fi
if [[ ! -x /opt/homebrew/bin/bash && ! -x /usr/local/bin/bash ]]; then
  echo "SKIP: no bash 4+ at /opt/homebrew/bin or /usr/local/bin"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/shim"
ln -s /bin/bash "${TMP}/shim/bash"

pass=0
fail=0

make_input() {
  jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

# check <description> <expected_exit> <command-text>
check() {
  local desc="$1" want="$2" cmdtext="$3"
  local got err
  err="$(make_input "${cmdtext}" \
    | PATH="${TMP}/shim:${PATH}" "${TMP}/shim/bash" "${HOOK}" 2>&1 >/dev/null)"
  got=$?
  if [[ "${got}" -ne "${want}" ]]; then
    printf 'FAIL: %s (want exit %s, got %s)\n' "${desc}" "${want}" "${got}"
    printf '      %s\n' "${err}" | head -3
    fail=$((fail + 1))
  elif printf '%s' "${err}" | grep -qE 'command not found|bad substitution|invalid option'; then
    printf 'FAIL: %s (bash error on stderr)\n' "${desc}"
    printf '      %s\n' "${err}" | head -3
    fail=$((fail + 1))
  else
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  fi
}

echo "=== Under bash 3.2, the chain runs to the end ==="
check "read-only gh call is allowed" 0 \
  "gh pr list --repo smartwatermelon/claude-config --limit 1"
check "plain git status is allowed" 0 "git status"

echo "=== Under bash 3.2, the chain still blocks ==="
check "REST merge is blocked" 2 \
  "gh api repos/smartwatermelon/claude-config/pulls/1/merge -X PUT"
check "git worktree add is blocked" 2 "git worktree add /tmp/x"

echo
echo "======================================="
printf 'Results: %d passed, %d failed\n' "${pass}" "${fail}"
echo "======================================="
[[ "${fail}" -eq 0 ]]
