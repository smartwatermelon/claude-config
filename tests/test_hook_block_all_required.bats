#!/usr/bin/env bats
# Tests for ~/.claude/scripts/hook-block-all.sh's required-hook check (#660)
#
# The dispatcher used to run each sub-hook only `if [[ -x "${hook}" ]]`, so a
# lost symlink disabled that guard without a word. It now fails closed: if a
# required hook is missing, dangling or not executable, it blocks (exit 2) and
# names the hook.
#
# Each test copies all of scripts/ into a temp dir (sub-hooks call helpers such
# as hook-block-secret-leak.py), so SCRIPT_DIR resolves there and the real
# scripts/ is never touched.
#
# Run: bats ~/.claude/tests/test_hook_block_all_required.bats

SCRIPTS="${BATS_TEST_DIRNAME}/../scripts"

# Blocked commands append to ${HOME}/.claude/blocked-commands.log. A sandbox
# HOME keeps these tests out of the real log.
setup() {
  SANDBOX_HOME="$(mktemp -d)"
  export HOME="${SANDBOX_HOME}"
  mkdir -p "${HOME}/.claude"
  HOOKDIR="${SANDBOX_HOME}/scripts"
  mkdir -p "${HOOKDIR}"
  cp -Rp "${SCRIPTS}/." "${HOOKDIR}/"
}

teardown() {
  rm -rf "${SANDBOX_HOME}"
}

_run_dispatcher() {
  local input
  input="$(jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}')"
  run bash -c "printf '%s' \"\$1\" | \"\$2\"" _ "${input}" "${HOOKDIR}/hook-block-all.sh"
}

@test "#660: all required hooks present: a benign command passes" {
  _run_dispatcher "git status"
  [ "${status}" -eq 0 ]
}

@test "#660: a missing required hook blocks and is named" {
  rm "${HOOKDIR}/hook-block-api-merge.sh"
  _run_dispatcher "git status"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"hook-block-api-merge.sh (missing)"* ]]
  [[ "${output}" == *"install.sh --sync"* ]]
}

@test "#660: a required hook that is not executable blocks and is named" {
  chmod -x "${HOOKDIR}/hook-block-git-worktree.sh"
  _run_dispatcher "git status"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"hook-block-git-worktree.sh (not executable)"* ]]
}

@test "#660: a dangling required hook symlink blocks and is named" {
  rm "${HOOKDIR}/hook-block-secret-leak.sh"
  ln -s "${SANDBOX_HOME}/gone/hook-block-secret-leak.sh" "${HOOKDIR}/hook-block-secret-leak.sh"
  _run_dispatcher "git status"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"hook-block-secret-leak.sh (dangling symlink)"* ]]
}

@test "#660: every failing hook is named, not only the first" {
  rm "${HOOKDIR}/hook-block-no-verify.sh"
  chmod -x "${HOOKDIR}/hook-check-commit-message.py"
  _run_dispatcher "git status"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"hook-block-no-verify.sh (missing)"* ]]
  [[ "${output}" == *"hook-check-commit-message.py (not executable)"* ]]
}
