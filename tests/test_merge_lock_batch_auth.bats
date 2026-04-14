#!/usr/bin/env bats
# Tests for merge-lock batch authorization (issue #108).
# Run: bats tests/test_merge_lock_batch_auth.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

setup() {
  TMP_HOME="$(mktemp -d)"
  export HOME="${TMP_HOME}"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/pr-$1.lock"
}

@test "single PR form still works" {
  run bash "${SCRIPT}" auth 100 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  grep -q "^PR_NUMBER=100$" "$(lock_file 100)"
  grep -q "^REASON=ok$" "$(lock_file 100)"
}

@test "comma-separated list writes one lock per PR" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "whitespace inside list is tolerated" {
  run bash "${SCRIPT}" auth "100, 204 ,553" "ok"
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 100)" ]
  [ -f "$(lock_file 204)" ]
  [ -f "$(lock_file 553)" ]
}

@test "all PRs share the same timestamp" {
  run bash "${SCRIPT}" auth 100,204,553 "ok"
  [ "${status}" -eq 0 ]
  ts100=$(grep "^TIMESTAMP=" "$(lock_file 100)" | cut -d= -f2)
  ts204=$(grep "^TIMESTAMP=" "$(lock_file 204)" | cut -d= -f2)
  ts553=$(grep "^TIMESTAMP=" "$(lock_file 553)" | cut -d= -f2)
  [ "${ts100}" = "${ts204}" ]
  [ "${ts204}" = "${ts553}" ]
}

@test "list form refuses when reason is missing" {
  run bash "${SCRIPT}" auth 100,204,553
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 204)" ]
}

@test "single PR form also refuses when reason is missing (tightened)" {
  run bash "${SCRIPT}" auth 100
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
}

@test "non-numeric entry rejects entire batch" {
  run bash "${SCRIPT}" auth "100,abc,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}

@test "empty element in list rejects entire batch" {
  run bash "${SCRIPT}" auth "100,,553" "ok"
  [ "${status}" -ne 0 ]
  [ ! -f "$(lock_file 100)" ]
  [ ! -f "$(lock_file 553)" ]
}
