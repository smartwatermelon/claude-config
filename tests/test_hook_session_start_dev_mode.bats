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
