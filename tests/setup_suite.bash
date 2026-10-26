# bats sources this first. A run of every tests/*.bats file fails; CI runs one file per bats call.
setup_suite() {
  local all=("${BATS_TEST_DIRNAME:?}"/*.bats)
  # bats-exec-suite sets this list (bats 1.10 through 1.14). Unset means bats changed: refuse loudly, not silently.
  if [[ -z "${BATS_UNIQUE_TEST_FILENAMES+set}" ]]; then
    echo 'setup_suite.bash: bats no longer sets BATS_UNIQUE_TEST_FILENAMES; fix the guard.' >&2
    return 1
  fi
  if ((${#BATS_UNIQUE_TEST_FILENAMES[@]} >= ${#all[@]})); then
    echo 'Only run the tests you specifically need, never all of them. Name the test files your change touches.' >&2
    return 1
  fi
}
