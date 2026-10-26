#!/usr/bin/env bats
# Tests for on-use purge of expired merge-lock authorizations (issue #295).
# Run: bats tests/test_merge_lock_purge_expired.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh"

# Read the TTL directly from the script rather than duplicating the literal,
# so this test stays correct if LOCK_TTL_SECONDS is ever changed in-script.
LOCK_TTL_SECONDS=$(grep -m1 "^LOCK_TTL_SECONDS=" "${BATS_TEST_DIRNAME}/../hooks/merge-lock.sh" | cut -d= -f2 | grep -o '^[0-9]*')

setup() {
  # The real gh is an exported shell function, and it shadows the PATH stub
  # below unless both it and BASH_ENV are cleared. Without this, every call
  # fails on the wrapper's identity check instead of reaching the stub
  # (claude-config#514, #477).
  unset BASH_ENV
  unset CDPATH
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true

  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"

  # Locks are keyed on repo + PR; stub gh so cwd resolution is offline.
  mkdir -p "${TMP_HOME}/bin"
  printf '#!/usr/bin/env bash\necho acme/widgets\n' >"${TMP_HOME}/bin/gh"
  chmod +x "${TMP_HOME}/bin/gh"
  export PATH="${TMP_HOME}/bin:${PATH}"
}

teardown() {
  # TMP_HOME is readonly so a test can't reassign it out from under teardown,
  # even if it reassigns HOME mid-test (see #116).
  # A read-only lock dir left by a failed test would stop rm -rf.
  chmod -R u+w "${TMP_HOME}"
  rm -rf "${TMP_HOME}"
}

lock_file() {
  echo "${TMP_HOME}/.claude/merge-locks/acme/widgets/pr-$1.lock"
}

write_backdated_lock() {
  local pr_number="$1"
  local age_seconds="$2"
  local lock_dir="${TMP_HOME}/.claude/merge-locks/acme/widgets"
  mkdir -p "${lock_dir}"
  local ts
  ts=$(($(date +%s) - age_seconds))
  {
    echo "PR_NUMBER=${pr_number}"
    echo "REPO=acme/widgets"
    echo "AUTHORIZED_BY=tester"
    echo "TIMESTAMP=${ts}"
    echo "REASON=test"
  } >"${lock_dir}/pr-${pr_number}.lock"
}

@test "list purges an expired lock file" {
  write_backdated_lock 100 $((LOCK_TTL_SECONDS + 60))
  [ -f "$(lock_file 100)" ]

  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Purged expired lock for acme/widgets#100"* ]]
  [ ! -f "$(lock_file 100)" ]
}

@test "list does not purge a still-valid lock file" {
  write_backdated_lock 200 60
  [ -f "$(lock_file 200)" ]

  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [ -f "$(lock_file 200)" ]
}

@test "status purges an expired lock file for a different PR" {
  write_backdated_lock 300 $((LOCK_TTL_SECONDS + 60))
  write_backdated_lock 301 60
  [ -f "$(lock_file 300)" ]

  run bash "${SCRIPT}" status 301
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 300)" ]
  [ -f "$(lock_file 301)" ]
}

@test "check purges expired locks for other PRs" {
  write_backdated_lock 400 $((LOCK_TTL_SECONDS + 60))
  write_backdated_lock 401 60

  run bash "${SCRIPT}" check 401
  [ "${status}" -eq 0 ]
  [ ! -f "$(lock_file 400)" ]
  [ -f "$(lock_file 401)" ]
}

@test "list with only expired locks reports none active" {
  write_backdated_lock 500 $((LOCK_TTL_SECONDS + 60))

  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(none)"* ]]
  [ ! -f "$(lock_file 500)" ]
}

@test "list on an empty lock dir does not error" {
  run bash "${SCRIPT}" list
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(none)"* ]]
}

# The Claude Code sandbox denies writes to the lock dir (#779). A read-only
# lock dir under TMP_HOME stands in for it: rm fails the same way.
make_lock_dir_read_only() {
  [ "$(id -u)" -ne 0 ] || skip "root ignores directory write permission"
  chmod 555 "${TMP_HOME}/.claude/merge-locks/acme/widgets"
}

restore_lock_dir() {
  chmod 755 "${TMP_HOME}/.claude/merge-locks/acme/widgets"
}

@test "check still answers for a valid lock when an expired one cannot be removed" {
  write_backdated_lock 600 $((LOCK_TTL_SECONDS + 60))
  write_backdated_lock 601 60
  make_lock_dir_read_only

  run bash "${SCRIPT}" check 601
  restore_lock_dir
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Authorized"* ]]
  [[ "${output}" == *"Could not remove expired lock"* ]]
  [ -f "$(lock_file 600)" ]
}

@test "check on an expired lock it cannot remove says Not authorized" {
  write_backdated_lock 610 $((LOCK_TTL_SECONDS + 60))
  make_lock_dir_read_only

  run bash "${SCRIPT}" check 610
  restore_lock_dir
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Not authorized"* ]]
}

@test "authorize purges expired locks for other PRs" {
  write_backdated_lock 700 $((LOCK_TTL_SECONDS + 60))
  write_backdated_lock 701 60

  run bash "${SCRIPT}" auth 702 "ok"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Purged expired lock for acme/widgets#700"* ]]
  [ ! -f "$(lock_file 700)" ]
  [ -f "$(lock_file 701)" ]
  [ -f "$(lock_file 702)" ]
}
