#!/usr/bin/env bats
# hook-session-start.sh announces dev mode (#453): ~/.claude linked to the
# working checkout instead of the deploy clone. stdout reaches the model as
# context; stderr reaches the human.
#
# HOME is a temp dir, so the host's real ~/.claude is never read.
#
# Run: bats tests/test_hook_session_start_dev_mode.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/hook-session-start.sh"
  export HOME="${BATS_TEST_TMPDIR}/home"
  unset PENDING_ISSUES_DIR REVIEW_STATE_DIR
  CLONE="${HOME}/.local/share/claude-config"
  DEV="${HOME}/Developer/claude-config"
  MARKER="${HOME}/.local/state/claude-config/dev-mode"
  mkdir -p "${HOME}/.claude/hooks" "${CLONE}/hooks" "${DEV}/hooks" "${MARKER%/*}"
  touch "${CLONE}/hooks/run-review.sh" "${DEV}/hooks/run-review.sh"
  STATE="${MARKER%/*}"
  unset CLAUDE_CONFIG_DEPLOY_STALE_HOURS
  # A fresh last-good stamp by default, so the dev-mode cases see no deploy notice.
  stamp 0
}

stamp() { # stamp <seconds ago>: the deploy script's last-good epoch
  local now
  now="$(date +%s)"
  printf '%s\n' "$((now - $1))" >"${STATE}/deploy.ok"
}

on_clone() {
  mkdir -p "${CLONE}/.git"
  ln -s "${CLONE}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
}

@test "linked to the deploy clone: silent" {
  mkdir -p "${CLONE}/.git"
  ln -s "${CLONE}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "no deploy clone: silent" {
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "dev mode: names the checkout and the command that ends it" {
  mkdir -p "${CLONE}/.git"
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  printf 'path=%s\nsince=%s\n' "${DEV}" "$(date +%s)" >"${MARKER}"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV MODE"* ]]
  [[ "${output}" == *"${DEV}"* ]]
  [[ "${output}" == *"claude-config-deploy"* ]]
}

@test "dev mode notice goes to stdout, so the session's model sees it" {
  mkdir -p "${CLONE}/.git"
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run bash -c 'bash "$1" </dev/null 2>/dev/null' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEV MODE"* ]]
}

# --- deploy health -----------------------------------------------------------

@test "deploy problem: names the key, the log, and the next command" {
  on_clone
  printf 'diverged\n' >"${STATE}/deploy.problem"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEPLOY PROBLEM (diverged)"* ]]
  [[ "${output}" == *"${STATE}/deploy.log"* ]]
  [[ "${output}" == *"claude-config-deploy status"* ]]
}

@test "deploy problem: stdout for the model, stderr with a warning for the human" {
  on_clone
  printf 'dirty\n' >"${STATE}/deploy.problem"
  run bash -c 'bash "$1" </dev/null 2>/dev/null' _ "${SCRIPT}"
  [[ "${output}" == "claude-config DEPLOY PROBLEM (dirty)"* ]]
  run bash -c 'bash "$1" </dev/null 2>&1 >/dev/null' _ "${SCRIPT}"
  [[ "${output}" == "⚠️  claude-config DEPLOY PROBLEM (dirty)"* ]]
}

@test "stale stamp: says how long, and names both checks" {
  on_clone
  stamp $((3 * 3600 + 60))
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEPLOY STALE"* ]]
  [[ "${output}" == *"has not completed a run in 3h"* ]]
  [[ "${output}" == *"claude-config-deploy status"* ]]
  [[ "${output}" == *"launchctl print gui/\$(id -u)/com.smartwatermelon.claude-config-deploy"* ]]
}

@test "stale stamp: notice goes to stdout too" {
  on_clone
  stamp $((2 * 86400 + 60))
  run bash -c 'bash "$1" </dev/null 2>/dev/null' _ "${SCRIPT}"
  [[ "${output}" == *"has not completed a run in 2d"* ]]
}

@test "no stamp: says the agent never recorded a run" {
  on_clone
  rm -f "${STATE}/deploy.ok"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"DEPLOY STALE"* ]]
  [[ "${output}" == *"never"* ]]
  [[ "${output}" != *"No such file"* ]]
}

@test "fresh stamp: silent" {
  on_clone
  stamp 60
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "threshold override: CLAUDE_CONFIG_DEPLOY_STALE_HOURS=1 flags a 90-minute-old stamp" {
  on_clone
  stamp $((90 * 60))
  CLAUDE_CONFIG_DEPLOY_STALE_HOURS=1 run bash "${SCRIPT}" </dev/null
  [[ "${output}" == *"has not completed a run in 1h"* ]]
}

@test "problem and stale: only the problem notice prints" {
  on_clone
  rm -f "${STATE}/deploy.ok"
  printf 'install-failed\n' >"${STATE}/deploy.problem"
  run bash "${SCRIPT}" </dev/null
  [[ "${output}" == *"DEPLOY PROBLEM (install-failed)"* ]]
  [[ "${output}" != *"STALE"* ]]
}

@test "no deploy clone: silent, even with a problem and no stamp" {
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  rm -f "${STATE}/deploy.ok"
  printf 'no-clone\n' >"${STATE}/deploy.problem"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
