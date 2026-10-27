#!/usr/bin/env bats
# Tests for scripts/ci-tests-scope.sh (#732). A stub gh runs the script's real --jq filter over canned compare JSON.
#
# Run: bats ~/Developer/claude-config/tests/test_ci_tests_scope.bats

bats_require_minimum_version 1.5.0

setup() {
  SCOPE="${BATS_TEST_DIRNAME}/../scripts/ci-tests-scope.sh"
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  STUB="$(mktemp -d)"
  # The stub logs its args, then exits GH_STUB_EXIT or pipes GH_STUB_JSON through the --jq filter it was given.
  cat >"${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"${GH_STUB_ARGS}"
[[ "${GH_STUB_EXIT:-0}" -eq 0 ]] || exit "${GH_STUB_EXIT}"
filter=""
while (($#)); do
  if [[ "$1" == "--jq" ]]; then
    filter="$2"
    break
  fi
  shift
done
[[ -n "${filter}" ]] || exit 99
printf '%s' "${GH_STUB_JSON}" | jq -r "${filter}"
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
  ONLY='{"files":[{"filename":"scripts/known-runtime.txt","status":"modified"}]}'
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
  scope GH_STUB_JSON='{"files":[{"filename":"scripts/known-runtime.txt"},{"filename":"scripts/run-tests.sh"}]}'
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=false" ]
}

@test "another file listed first, then known-runtime.txt: does not skip" {
  scope GH_STUB_JSON='{"files":[{"filename":"README.md"},{"filename":"scripts/known-runtime.txt"}]}'
  [ "${output}" = "skip=false" ]
}

@test "a rename onto known-runtime.txt: does not skip, because the jq filter emits the old path" {
  scope GH_STUB_JSON='{"files":[{"filename":"scripts/known-runtime.txt","status":"renamed","previous_filename":"scripts/update-tools.sh"}]}'
  [ "${output}" = "skip=false" ]
  [[ "${stderr}" == *"scripts/update-tools.sh changed"* ]]
}

@test "a file with the same basename elsewhere: does not skip" {
  scope GH_STUB_JSON='{"files":[{"filename":"known-runtime.txt"}]}'
  [ "${output}" = "skip=false" ]
}

@test "gh fails (unreadable list): does not skip" {
  scope GH_STUB_JSON="${ONLY}" GH_STUB_EXIT=1
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

@test "malformed JSON from gh: does not skip" {
  scope GH_STUB_JSON='not json'
  [ "${output}" = "skip=false" ]
}

@test "empty file list: does not skip" {
  scope GH_STUB_JSON='{"files":[]}'
  [ "${output}" = "skip=false" ]
}

@test "PR_HEAD_SHA unset: does not skip and does not call gh" {
  scope -u PR_HEAD_SHA GH_STUB_JSON="${ONLY}"
  [ "${output}" = "skip=false" ]
  [ ! -e "${GH_STUB_ARGS}" ]
}

@test "GITHUB_REPOSITORY unset: does not skip" {
  scope -u GITHUB_REPOSITORY GH_STUB_JSON="${ONLY}"
  [ "${output}" = "skip=false" ]
}

# The one case that skips.

@test "known-runtime.txt alone: skips" {
  scope GH_STUB_JSON="${ONLY}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "skip=true" ]
}

@test "queries the three-dot compare of the event SHAs, paginated" {
  scope GH_STUB_JSON="${ONLY}"
  run cat "${GH_STUB_ARGS}"
  [[ "${output}" == *"--paginate repos/owner/repo/compare/basesha...headsha"* ]]
}

# The skip is safe only while no suite reads known-runtime.txt. A suite that starts to must update the script first.
# Exempt, line by line: test-update-tools-deploy-clone.sh runs update-tools.sh with HOME in a mktemp dir and its own
# fixture known-runtime.txt (#453). Any other line in that file that matches still fails.
_reviewed_hits() {
  cat <<'EOF'
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update-tools.sh"
  printf '# Directories\nprojects\n\n# Files\n.claude.json\n' >"${dir}/scripts/known-runtime.txt"
echo "=== update-tools.sh and the deploy clone ==="
check "--learn: writes the working checkout's known-runtime.txt" grep -qx newthing "${DEV}/scripts/known-runtime.txt"
EOF
}

# Drops a hit only when its file is the exempt suite and its text is exactly one of the reviewed lines.
_drop_reviewed() {
  local list="${BATS_TEST_TMPDIR:?}/reviewed-hits"
  _reviewed_hits >"${list}"
  awk -v exempt='/scripts/tests/test-update-tools-deploy-clone.sh' 'NR == FNR { ok[$0] = 1; next }
    { i = index($0, ":"); f = substr($0, 1, i - 1); rest = substr($0, i + 1); j = index(rest, ":"); t = substr(rest, j + 1) }
    !(substr(f, length(f) - length(exempt) + 1) == exempt && (t in ok))' "${list}" -
}

@test "no test suite reads known-runtime.txt or runs update-tools.sh" {
  local hits dir
  # grep errors are swallowed below, so prove every searched path exists; a missing one would pass silently.
  for dir in tests scripts/tests hooks/tests test-pre-merge-review.sh; do
    [ -e "${REPO_ROOT}/${dir}" ]
  done
  hits="$(grep -rnE 'known-runtime|update-tools\.sh' "${REPO_ROOT}/tests" "${REPO_ROOT}/scripts/tests" \
    "${REPO_ROOT}/hooks/tests" "${REPO_ROOT}/test-pre-merge-review.sh" \
    | grep -v '/tests/test_ci_tests_scope\.bats:' | _drop_reviewed \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "${hits}" ]]; then
    echo "these suite lines touch known-runtime.txt; make ci-tests-scope.sh stop skipping for it:"
    echo "${hits}"
    return 1
  fi
}

@test "the line exemption still catches a new hit in the exempt suite" {
  local out
  local line="x/scripts/tests/test-update-tools-deploy-clone.sh:99:cat \"\${REPO_ROOT}/scripts/known-runtime.txt\""
  out="$(_drop_reviewed <<<"${line}")"
  [ "${out}" = "${line}" ]
  local ok='x/scripts/tests/test-update-tools-deploy-clone.sh:59:echo "=== update-tools.sh and the deploy clone ==="'
  out="$(_drop_reviewed <<<"${ok}")"
  [ -z "${out}" ]
  local other='x/scripts/tests/test-other.sh:59:echo "=== update-tools.sh and the deploy clone ==="'
  out="$(_drop_reviewed <<<"${other}")"
  [ "${out}" = "${other}" ]
}
