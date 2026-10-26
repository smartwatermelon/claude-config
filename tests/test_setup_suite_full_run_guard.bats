#!/usr/bin/env bats
# Tests for tests/setup_suite.bash: a run of every tests/*.bats file warns and fails; a run of some files works.
#
# Run: bats ~/Developer/claude-config/tests/test_setup_suite_full_run_guard.bats

bats_require_minimum_version 1.5.0

setup() {
  WORK="$(mktemp -d)"
  mkdir "${WORK}/tests"
  cp "${BATS_TEST_DIRNAME}/setup_suite.bash" "${WORK}/tests/"
  for name in a b c; do
    printf '@test "%s" { true; }\n' "${name}" >"${WORK}/tests/test_${name}.bats"
  done
}

teardown() {
  rm -r -- "${WORK}"
}

@test "bats on the directory warns and fails without running a test" {
  run bats "${WORK}/tests"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"Only run the tests you specifically need, never all of them."* ]]
  [[ "${output}" != *"ok 1 a"* ]]
}

@test "bats on every file by name warns and fails" {
  run bats "${WORK}/tests/test_a.bats" "${WORK}/tests/test_b.bats" "${WORK}/tests/test_c.bats"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never all of them"* ]]
}

@test "bats on one file runs it" {
  run bats "${WORK}/tests/test_a.bats"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok 1 a"* ]]
}

@test "bats on some files runs them" {
  run bats "${WORK}/tests/test_a.bats" "${WORK}/tests/test_b.bats"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ok 2 b"* ]]
}
