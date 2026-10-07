#!/usr/bin/env bats
# Tests for skills/reload/reload.sh, the script the /reload skill injects.
# It must exit 0 on every path: a failing injected command aborts the skill,
# and the reason never reaches the conversation.
#
# Run: bats tests/test_reload_skill.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../skills/reload/reload.sh"
}

@test "outside claude-wrapper: explains reload is unavailable, exits 0" {
  run env -u CLAUDE_WRAPPER_RELOAD_CMD bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RELOAD UNAVAILABLE"* ]]
}

@test "requester succeeds: passes its output through" {
  printf '#!/usr/bin/env bash\necho "Restarting Claude Code (PID 1)..."\n' \
    >"${BATS_TEST_TMPDIR}/ok"
  chmod +x "${BATS_TEST_TMPDIR}/ok"
  run env CLAUDE_WRAPPER_RELOAD_CMD="${BATS_TEST_TMPDIR}/ok" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Restarting Claude Code"* ]]
  [[ "${output}" != *"RELOAD FAILED"* ]]
}

@test "requester fails: its stderr reaches stdout with RELOAD FAILED, exits 0" {
  printf '#!/usr/bin/env bash\necho "claude-reload: nested session" >&2\nexit 1\n' \
    >"${BATS_TEST_TMPDIR}/fail"
  chmod +x "${BATS_TEST_TMPDIR}/fail"
  # Skill injection may not capture stderr, so check stdout alone
  run --separate-stderr env CLAUDE_WRAPPER_RELOAD_CMD="${BATS_TEST_TMPDIR}/fail" bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nested session"* ]]
  [[ "${output}" == *"RELOAD FAILED"* ]]
}
