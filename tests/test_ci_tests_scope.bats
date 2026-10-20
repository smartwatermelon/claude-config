#!/usr/bin/env bats
# Tests for scripts/ci-tests-scope.sh (#732). A stub gh on PATH prints a canned file list or fails.
#
# Run: bats ~/Developer/claude-config/tests/test_ci_tests_scope.bats

bats_require_minimum_version 1.5.0

setup() {
  SCOPE="${BATS_TEST_DIRNAME}/../scripts/ci-tests-scope.sh"
  STUB="$(mktemp -d)"
  # The stub logs its args, then prints GH_STUB_LIST (one path per line) or exits GH_STUB_EXIT.
  cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${GH_STUB_ARGS}"
[[ "${GH_STUB_EXIT:-0}" -eq 0 ]] || exit "${GH_STUB_EXIT}"
printf '%s' "${GH_STUB_LIST:-}"
EOF
  chmod +x "${STUB}/gh"
  # A dev shell may export a gh wrapper function that would shadow the stub, and GH_TOKEN makes it refuse.
  unset -f gh
  unset GH_TOKEN GITHUB_TOKEN
  export PATH="${STUB}:${PATH}"
  export GH_STUB_ARGS="${STUB}/args"
  export GITHUB_REPOSITORY="owner/repo"
  export PR_BASE_SHA="basesha"
  export PR_HEAD_SHA="headsha"
  ONLY=$'scripts/known-runtime.txt\n'
}

teardown() {
  rm -rf "${STUB}"
}

# scope VAR=value... : run the script with extra env, stdout in output and stderr in stderr.
scope() {
  run --separate-stderr env "$@" "${SCOPE}"
}

# Known-bad cases first: each one must NOT skip.

@test "known-runtime.txt plus another file: does not skip" {
  scope GH_STUB_LIST=$'scripts/known-runtime.txt\nscripts/run-tests.sh\n'
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=false" ]
}

@test "another file listed first, then known-runtime.txt: does not skip" {
  scope GH_STUB_LIST=$'README.md\nscripts/known-runtime.txt\n'
  [ "${output}" = "skip=false" ]
}

@test "a rename onto known-runtime.txt (old path listed too): does not skip" {
  # The jq filter emits filename then previous_filename, so a rename yields both paths.
  scope GH_STUB_LIST=$'scripts/known-runtime.txt\nscripts/update-tools.sh\n'
  [ "${output}" = "skip=false" ]
}

@test "a file with the same basename elsewhere: does not skip" {
  scope GH_STUB_LIST=$'known-runtime.txt\n'
  [ "${output}" = "skip=false" ]
}

@test "gh fails (unreadable list): does not skip" {
  scope GH_STUB_LIST="${ONLY}" GH_STUB_EXIT=1
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=false" ]
  [[ "${stderr}" == *"cannot read the changed-file list"* ]]
}

@test "gh missing from PATH: does not skip" {
  rm -f "${STUB}/gh"
  # PATH holds only the now-empty stub dir; the runner image ships a real gh in /usr/bin.
  run --separate-stderr env PATH="${STUB}" "${BASH}" "${SCOPE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=false" ]
}

@test "empty list: does not skip" {
  scope GH_STUB_LIST=""
  [ "${output}" = "skip=false" ]
}

@test "PR_HEAD_SHA unset: does not skip and does not call gh" {
  scope -u PR_HEAD_SHA GH_STUB_LIST="${ONLY}"
  [ "${output}" = "skip=false" ]
  [ ! -e "${GH_STUB_ARGS}" ]
}

@test "GITHUB_REPOSITORY unset: does not skip" {
  scope -u GITHUB_REPOSITORY GH_STUB_LIST="${ONLY}"
  [ "${output}" = "skip=false" ]
}

# The one case that skips.

@test "known-runtime.txt alone: skips" {
  scope GH_STUB_LIST="${ONLY}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=true" ]
}

@test "known-runtime.txt alone, no trailing newline: skips" {
  scope GH_STUB_LIST="scripts/known-runtime.txt"
  [ "${output}" = "skip=true" ]
}

@test "queries the three-dot compare of the event SHAs, paginated" {
  scope GH_STUB_LIST="${ONLY}"
  run cat "${GH_STUB_ARGS}"
  [[ "${output}" == *"--paginate repos/owner/repo/compare/basesha...headsha"* ]]
}
