#!/usr/bin/env bats
# hook-session-start.sh counts unfiled review findings in the new state dir
# (~/.local/state/claude-review/pending-issues) and in the old ~/.claude one.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/hook-session-start.sh"
  export HOME="${BATS_TEST_TMPDIR}/home"
  NEW_DIR="${HOME}/.local/state/claude-review/pending-issues"
  OLD_DIR="${HOME}/.claude/pending-issues"
  unset PENDING_ISSUES_DIR
}

@test "no queue directories: silent, exit 0" {
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "new state dir is counted" {
  mkdir -p "${NEW_DIR}"
  touch "${NEW_DIR}/a.md" "${NEW_DIR}/b.md"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"2 unfiled review finding(s) in ${NEW_DIR}"* ]]
}

@test "old ~/.claude dir is still counted" {
  mkdir -p "${OLD_DIR}"
  touch "${OLD_DIR}/a.md"
  run bash "${SCRIPT}" </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"1 unfiled review finding(s) in ${OLD_DIR}"* ]]
}

@test "both dirs reported separately" {
  mkdir -p "${NEW_DIR}" "${OLD_DIR}"
  touch "${NEW_DIR}/a.md" "${OLD_DIR}/b.md" "${OLD_DIR}/c.md"
  run bash "${SCRIPT}" </dev/null
  [[ "${output}" == *"1 unfiled review finding(s) in ${NEW_DIR}"* ]]
  [[ "${output}" == *"2 unfiled review finding(s) in ${OLD_DIR}"* ]]
}

@test "PENDING_ISSUES_DIR override reads only that dir" {
  mkdir -p "${OLD_DIR}" "${BATS_TEST_TMPDIR}/custom"
  touch "${OLD_DIR}/a.md" "${BATS_TEST_TMPDIR}/custom/x.md"
  PENDING_ISSUES_DIR="${BATS_TEST_TMPDIR}/custom" run bash "${SCRIPT}" </dev/null
  [[ "${output}" == *"1 unfiled review finding(s) in ${BATS_TEST_TMPDIR}/custom"* ]]
  [[ "${output}" != *"${OLD_DIR}"* ]]
}
