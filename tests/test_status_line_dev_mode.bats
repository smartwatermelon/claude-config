#!/usr/bin/env bats
# The status line flags a machine whose ~/.claude is not on the deploy clone (#453).
#
# After the deploy clone exists, ~/.claude/hooks/run-review.sh links into it.
# `install.sh --dev` links it to the working checkout instead, and that state
# must be visible in every session so it is never left on by accident. The
# link itself is the truth, so the segment reads the link, not the marker.
#
# HOME is a temp dir, so the host's real ~/.claude is never read.
#
# Run: bats tests/test_status_line_dev_mode.bats

SL="${BATS_TEST_DIRNAME}/../scripts/status-line.sh"
INPUT='{"workspace":{"current_dir":"/tmp"}}'

setup() {
  export HOME="${BATS_TEST_TMPDIR}/home"
  export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  CLONE="${HOME}/.local/share/claude-config"
  DEV="${HOME}/Developer/claude-config"
  mkdir -p "${CLAUDE_CONFIG_DIR}" "${HOME}/.claude/hooks" "${CLONE}/hooks" "${DEV}/hooks"
  touch "${CLONE}/hooks/run-review.sh" "${DEV}/hooks/run-review.sh"
}

render() {
  printf '%s' "${INPUT}" | bash "${SL}" | sed -e 's/\x1b\[[0-9;]*m//g'
}

@test "no deploy clone: no dev segment" {
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"DEV"* ]]
}

@test "linked to the deploy clone: no dev segment" {
  mkdir -p "${CLONE}/.git"
  ln -s "${CLONE}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"DEV"* ]]
}

@test "linked to the working checkout: the line starts with the dev segment" {
  mkdir -p "${CLONE}/.git"
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[DEV hooks] "* ]]
}

@test "no hook link at all while the clone exists: says so" {
  mkdir -p "${CLONE}/.git"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[hooks unlinked] "* ]]
}
