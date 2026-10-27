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
  STATE="${HOME}/.local/state/claude-config"
  mkdir -p "${STATE}"
  unset CLAUDE_CONFIG_DEPLOY_STALE_HOURS
  # A fresh last-good stamp by default, so the dev-mode cases see no deploy segment.
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

# --- deploy health -----------------------------------------------------------
# A refused run notifies once; a dead LaunchAgent writes nothing. Both must show.

@test "deploy problem: red segment names the key" {
  on_clone
  printf 'diverged\n' >"${STATE}/deploy.problem"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[DEPLOY: diverged] "* ]]
}

@test "deploy problem: the key is reduced to a safe short token" {
  on_clone
  local long
  long="$(printf 'z%.0s' {1..40})"
  printf 'bad key;|<x>\033[31m%s\n' "${long}" >"${STATE}/deploy.problem"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[DEPLOY: badkeyx31mzzzzzzzzzzzzzz] "* ]]
}

@test "deploy problem: an empty file still shows" {
  on_clone
  : >"${STATE}/deploy.problem"
  run render
  [[ "${output}" == "[DEPLOY: unknown] "* ]]
}

@test "stale stamp: shows the age in hours" {
  on_clone
  stamp $((3 * 3600 + 60))
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[DEPLOY stale 3h] "* ]]
}

@test "stale stamp: shows the age in days" {
  on_clone
  stamp $((2 * 86400 + 60))
  run render
  [[ "${output}" == "[DEPLOY stale 2d] "* ]]
}

@test "no stamp: stale never" {
  on_clone
  rm -f "${STATE}/deploy.ok"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[DEPLOY stale never] "* ]]
}

@test "unreadable stamp: says so rather than a made-up age" {
  on_clone
  printf 'garbage\n' >"${STATE}/deploy.ok"
  run render
  [[ "${output}" == "[DEPLOY stale unreadable] "* ]]
}

@test "fresh stamp: no deploy segment" {
  on_clone
  stamp 60
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"DEPLOY"* ]]
}

@test "just under the 2h default: no deploy segment" {
  on_clone
  stamp $((2 * 3600 - 120))
  run render
  [[ "${output}" != *"DEPLOY"* ]]
}

@test "stamp from the future (clock change): no deploy segment" {
  on_clone
  stamp -3600
  run render
  [[ "${output}" != *"DEPLOY"* ]]
}

@test "threshold override: CLAUDE_CONFIG_DEPLOY_STALE_HOURS=1 flags a 90-minute-old stamp" {
  on_clone
  stamp $((90 * 60))
  CLAUDE_CONFIG_DEPLOY_STALE_HOURS=1 run render
  [[ "${output}" == "[DEPLOY stale 1h] "* ]]
}

@test "problem and stale: only the problem shows" {
  on_clone
  rm -f "${STATE}/deploy.ok"
  printf 'dirty\n' >"${STATE}/deploy.problem"
  run render
  [[ "${output}" == "[DEPLOY: dirty] "* ]]
  [[ "${output}" != *"stale"* ]]
}

@test "no deploy clone: no deploy segment, even with a problem and no stamp" {
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  rm -f "${STATE}/deploy.ok"
  printf 'no-clone\n' >"${STATE}/deploy.problem"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"DEPLOY"* ]]
}

@test "dev mode and a problem: both show, dev first" {
  mkdir -p "${CLONE}/.git"
  ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  printf 'dirty\n' >"${STATE}/deploy.problem"
  run render
  [[ "${output}" == "[DEV hooks] [DEPLOY: dirty] "* ]]
}
