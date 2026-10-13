#!/usr/bin/env bats
# Tests for scripts/install-reviewer-api-key.sh, which copies the reviewer
# API key from 1Password into the login Keychain for hooks/run-review.sh.
#
# Every external is a mock (op, curl, security) and the "keychain" is a
# scratch file, so no test reads 1Password, calls the API, or touches a real
# keychain. The cases pin: the happy path stores and verifies the key and
# leaves a byte-identical backup; every validation failure exits non-zero
# BEFORE the backup step, so a bad value leaves no backup behind; the key is
# never printed and never passed in argv.
#
# Run: bats tests/test_install_reviewer_api_key.bats

SCRIPT="${BATS_TEST_DIRNAME:-}/../scripts/install-reviewer-api-key.sh"
GOOD_KEY="sk-ant-api03-TESTKEY_abc-123"

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export REVIEWER_KEY_KEYCHAIN="${MOCK_DIR}/fake.keychain-db"
  printf 'fake keychain bytes\n' >"${REVIEWER_KEY_KEYCHAIN}"
  export REVIEWER_KEY_BACKUP_DIR="${MOCK_DIR}/backups"
  export REVIEWER_KEY_OP_BIN="${MOCK_DIR}/op"
  export REVIEWER_KEY_CURL_BIN="${MOCK_DIR}/curl"
  export REVIEWER_KEY_SECURITY_BIN="${MOCK_DIR}/security"
  export USER="testuser"
  printf '%s' "${GOOD_KEY}" >"${MOCK_DIR}/op-value"
  printf '200' >"${MOCK_DIR}/http-code"

  # op: `op read <ref>` prints op-value, or fails when op-fail exists.
  cat >"${MOCK_DIR}/op" <<'EOF'
#!/usr/bin/env bash
[[ -f "${MOCK_DIR}/op-fail" ]] && { echo "op: not signed in" >&2; exit 1; }
[[ "$1" == "read" ]] || exit 2
cat "${MOCK_DIR}/op-value"
EOF
  # curl: records argv and stdin (the header), prints the HTTP code.
  cat >"${MOCK_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_DIR}/curl-argv"
cat >>"${MOCK_DIR}/curl-stdin"
cat "${MOCK_DIR}/http-code"
EOF
  # security: `-i` reads an add-generic-password line from stdin and stores
  # the -w value; `find-generic-password ... -w` prints it back.
  cat >"${MOCK_DIR}/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_DIR}/security-argv"
if [[ "$1" == "-i" ]]; then
  read -r -a words
  [[ "${words[0]}" == "add-generic-password" ]] || exit 1
  for ((i = 0; i < ${#words[@]}; i++)); do
    [[ "${words[i]}" == "-w" ]] && printf '%s' "${words[i + 1]}" >"${MOCK_DIR}/stored"
  done
  exit 0
fi
if [[ "$1" == "find-generic-password" ]]; then
  [[ -f "${MOCK_DIR}/stored" ]] || exit 44
  cat "${MOCK_DIR}/stored"
  exit 0
fi
exit 1
EOF
  chmod +x "${MOCK_DIR}/op" "${MOCK_DIR}/curl" "${MOCK_DIR}/security"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

_no_backup() {
  [[ -d "${REVIEWER_KEY_BACKUP_DIR}" ]] || return 0
  local found
  found=$(find "${REVIEWER_KEY_BACKUP_DIR}" -mindepth 1 -print -quit) || return 1
  [[ -z "${found}" ]]
}

@test "success: stores the key, verifies it, leaves an identical backup" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$(<"${MOCK_DIR}/stored")" == "${GOOD_KEY}" ]]
  [[ "$output" == *"Stored claude-reviewer-api-key (account testuser, length ${#GOOD_KEY})"* ]]
  backup=$(ls "${REVIEWER_KEY_BACKUP_DIR}"/fake.keychain-db.*)
  cmp -s "${REVIEWER_KEY_KEYCHAIN}" "${backup}"
  # Never printed, never in any argv; the API check got it on stdin.
  [[ "$output" != *"${GOOD_KEY}"* ]]
  ! grep -qF "${GOOD_KEY}" "${MOCK_DIR}/curl-argv" "${MOCK_DIR}/security-argv" || false
  grep -qF "x-api-key: ${GOOD_KEY}" "${MOCK_DIR}/curl-stdin"
}

@test "op failure: exits non-zero, no backup, nothing written" {
  touch "${MOCK_DIR}/op-fail"
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"op read failed"* ]]
  _no_backup
  [ ! -e "${MOCK_DIR}/stored" ]
}

@test "admin key rejected before backup" {
  printf 'sk-ant-admin01-abcdef' >"${MOCK_DIR}/op-value"
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"admin key or OAuth token"* ]]
  [[ "$output" != *"sk-ant-admin01-abcdef"* ]]
  _no_backup
  [ ! -e "${MOCK_DIR}/curl-argv" ]
  [ ! -e "${MOCK_DIR}/stored" ]
}

@test "OAuth token (sk-ant-oat) rejected before backup" {
  printf 'sk-ant-oat01-abcdef' >"${MOCK_DIR}/op-value"
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"admin key or OAuth token"* ]]
  _no_backup
  [ ! -e "${MOCK_DIR}/stored" ]
}

@test "a value that is not an Anthropic key is rejected, length only" {
  printf 'hunter2 with spaces' >"${MOCK_DIR}/op-value"
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"is not an Anthropic key (length 19)"* ]]
  [[ "$output" != *"hunter2"* ]]
  _no_backup
}

@test "API rejects the key (HTTP 401): exits non-zero, no backup" {
  printf '401' >"${MOCK_DIR}/http-code"
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"rejected by"*"(HTTP 401)"* ]]
  [[ "$output" != *"${GOOD_KEY}"* ]]
  _no_backup
  [ ! -e "${MOCK_DIR}/stored" ]
}

@test "stored value differs from 1Password: exits non-zero, names the backup" {
  # A security mock that stores a different value than it was given.
  cat >"${MOCK_DIR}/security" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-i" ]] && { cat >/dev/null; exit 0; }
printf 'sk-ant-api03-other'
EOF
  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stored value differs"*"backup at"* ]]
  [[ "$output" != *"${GOOD_KEY}"* ]]
}
