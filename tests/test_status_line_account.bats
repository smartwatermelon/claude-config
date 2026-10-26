#!/usr/bin/env bats
# Tests for the account segment of ~/.claude/scripts/status-line.sh
#
# Several Claude accounts share one machine, switched with /login, and nothing
# on screen said which one a session used. The statusLine stdin has no account
# field, so the script reads oauthAccount.emailAddress from .claude.json.
#
# WHAT THESE TESTS ARE DEFENDING:
#
#   1. The file is found through CLAUDE_CONFIG_DIR when set, so a fixture dir
#      here stands in for the real one and no test reads the host's login.
#   2. A labels file maps an exact email to a short label; a near-miss email
#      must not borrow another account's label.
#   3. No login, no file, or an unparsable file prints no segment and exits 0.
#
# Run: bats ~/.claude/tests/test_status_line_account.bats

SL="${BATS_TEST_DIRNAME}/../scripts/status-line.sh"
INPUT='{"workspace":{"current_dir":"/tmp"}}'

setup() {
  export CLAUDE_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  mkdir -p "${CLAUDE_CONFIG_DIR}"
}

render() {
  printf '%s' "${INPUT}" | bash "${SL}" | sed -e 's/\x1b\[[0-9;]*m//g'
}

@test "shows the logged-in email when no labels file exists" {
  printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[a@example.com] "* ]]
}

@test "labels file replaces the email with its label" {
  printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  printf '%s\n' '# comment' 'b@example.com=other' 'a@example.com=work' \
    >"${CLAUDE_CONFIG_DIR}/account-labels"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[work] "* ]]
}

@test "labels file without a trailing newline still matches its last line" {
  printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  printf '%s' 'a@example.com=work' >"${CLAUDE_CONFIG_DIR}/account-labels"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[work] "* ]]
}

@test "spaces around = in the labels file are ignored" {
  printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  printf '%s\n' '  a@example.com = work  ' >"${CLAUDE_CONFIG_DIR}/account-labels"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[work] "* ]]
}

@test "CRLF line endings in the labels file do not leak into the label" {
  printf '%s' '{"oauthAccount":{"emailAddress":"a@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  printf 'b@example.com=other\r\na@example.com=work\r\n' \
    >"${CLAUDE_CONFIG_DIR}/account-labels"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[work] "* ]]
}

@test "a near-miss email does not take another account's label" {
  printf '%s' '{"oauthAccount":{"emailAddress":"xa@example.com"}}' \
    >"${CLAUDE_CONFIG_DIR}/.claude.json"
  printf '%s\n' 'a@example.com=work' >"${CLAUDE_CONFIG_DIR}/account-labels"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" == "[xa@example.com] "* ]]
}

@test "no oauthAccount prints no segment and exits 0" {
  printf '%s' '{}' >"${CLAUDE_CONFIG_DIR}/.claude.json"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"["*"@"*"]"* ]]
  [[ "${output}" == *"/tmp"* ]]
}

@test "missing .claude.json prints no segment and exits 0" {
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != "["* ]]
  [[ "${output}" == *"/tmp"* ]]
}

@test "unparsable .claude.json prints no segment and exits 0" {
  printf '%s' 'not json' >"${CLAUDE_CONFIG_DIR}/.claude.json"
  run render
  [ "${status}" -eq 0 ]
  [[ "${output}" != "["* ]]
  [[ "${output}" == *"/tmp"* ]]
}
