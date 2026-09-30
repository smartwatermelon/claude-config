#!/usr/bin/env bats
# Tests for scripts/run-tests.sh, the runner that .project-hooks/pre-push and
# CI both call. RUN_TESTS_ROOT points it at a scratch tree of fake suites, so
# these tests never run (or recurse into) the real suite.
#
# Run: bats ~/Developer/claude-config/tests/test_run_tests.bats

bats_require_minimum_version 1.5.0

setup() {
  RUNNER="${BATS_TEST_DIRNAME}/../scripts/run-tests.sh"
  PRE_PUSH="${BATS_TEST_DIRNAME}/../.project-hooks/pre-push"
  FAKE="$(mktemp -d)"
  mkdir -p "${FAKE}/tests" "${FAKE}/scripts/tests" "${FAKE}/hooks/tests"
  export RUN_TESTS_ROOT="${FAKE}"
}

teardown() {
  rm -rf "${FAKE}"
}

# pass_bats <name> / fail_bats <name> / pass_sh <name> / fail_sh <name>
pass_bats() { printf '#!/usr/bin/env bats\n@test "ok" { true; }\n' >"${FAKE}/tests/$1.bats"; }
fail_bats() { printf '#!/usr/bin/env bats\n@test "bad" { echo marker-%s; false; }\n' "$1" >"${FAKE}/tests/$1.bats"; }
pass_sh() { printf 'exit 0\n' >"${FAKE}/scripts/tests/test-$1.sh"; }
fail_sh() { printf 'echo marker-%s; exit 1\n' "$1" >"${FAKE}/scripts/tests/test-$1.sh"; }

@test "all suites pass: exit 0 and one PASS line per suite" {
  pass_bats a
  pass_sh b
  printf 'exit 0\n' >"${FAKE}/test-pre-merge-review.sh"
  run "${RUNNER}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PASS  tests/a.bats"* ]]
  [[ "${output}" == *"PASS  scripts/tests/test-b.sh"* ]]
  [[ "${output}" == *"PASS  test-pre-merge-review.sh"* ]]
  [[ "${output}" == *"All 3 suites passed."* ]]
}

@test "a failing bats suite: exit 1 and its output is shown" {
  fail_bats a
  pass_sh b
  run "${RUNNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  tests/a.bats"* ]]
  [[ "${output}" == *"marker-a"* ]]
}

@test "a failing shell suite: exit 1 and its output is shown" {
  pass_bats a
  fail_sh b
  run "${RUNNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  scripts/tests/test-b.sh"* ]]
  [[ "${output}" == *"marker-b"* ]]
}

@test "a failing hooks/tests suite is not skipped" {
  pass_sh b
  printf 'exit 1\n' >"${FAKE}/hooks/tests/run-review-test.sh"
  run "${RUNNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  hooks/tests/run-review-test.sh"* ]]
}

@test "a failing root test-pre-merge-review.sh is not skipped" {
  pass_sh b
  printf 'exit 1\n' >"${FAKE}/test-pre-merge-review.sh"
  run "${RUNNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  test-pre-merge-review.sh"* ]]
}

@test "without --fail-fast every suite runs and every failure is listed" {
  fail_bats a
  fail_sh b
  fail_sh c
  run "${RUNNER}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"3 suite(s) failed"* ]]
  [[ "${output}" == *"marker-c"* ]]
}

@test "--fail-fast stops at the first failure" {
  fail_bats a
  fail_sh b
  run "${RUNNER}" --fail-fast
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL  tests/a.bats"* ]]
  [[ "${output}" != *"test-b.sh"* ]]
}

@test "each suite runs with a fresh sandbox HOME, never the caller's" {
  # Each suite fails if HOME is the caller's, or if an earlier suite's marker
  # is visible, then leaves a marker of its own.
  for n in b c; do
    printf '[ "$HOME" != "%s" ] || exit 1\n[ ! -e "$HOME/marker" ] || exit 1\n[ "$XDG_CONFIG_HOME" = "$HOME/.config" ] || exit 1\ntouch "$HOME/marker"\n' \
      "${HOME}" >"${FAKE}/scripts/tests/test-${n}.sh"
  done
  run "${RUNNER}"
  [ "${status}" -eq 0 ]
  [ ! -e "${HOME}/marker" ]
}

@test "GH_WRAPPER_LIB is resolved from the caller's HOME before the sandbox" {
  local caller_home="${FAKE}/caller"
  mkdir -p "${caller_home}/.config/bash"
  : >"${caller_home}/.config/bash/gh-wrapper.sh"
  printf '[ "$GH_WRAPPER_LIB" = "%s" ]\n' "${caller_home}/.config/bash/gh-wrapper.sh" \
    >"${FAKE}/scripts/tests/test-b.sh"
  run env -u GH_WRAPPER_LIB HOME="${caller_home}" "${RUNNER}"
  [ "${status}" -eq 0 ]
}

@test "an explicit GH_WRAPPER_LIB is kept" {
  printf '[ "$GH_WRAPPER_LIB" = /x/gh-wrapper.sh ]\n' >"${FAKE}/scripts/tests/test-b.sh"
  run env GH_WRAPPER_LIB=/x/gh-wrapper.sh "${RUNNER}"
  [ "${status}" -eq 0 ]
}

@test "no suites found is an error, not a pass" {
  run "${RUNNER}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"no test suites found"* ]]
}

@test "an unknown argument is a usage error" {
  pass_sh b
  run "${RUNNER}" --bogus
  [ "${status}" -eq 2 ]
}

@test "the pre-push extension is executable, or run_project_extensions skips it" {
  [ -x "${PRE_PUSH}" ]
}
