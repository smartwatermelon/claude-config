#!/usr/bin/env bats
# Split guard: policy keys live in machine-settings/base.json, not in the
# preferences file. Hooks merge across scopes, so a key in both runs twice.
#
# SETTINGS_PREFS_FILE overrides the preferences file, so the guard can be
# checked against a known-bad copy.
#
# Run: bats ~/Developer/claude-config/tests/test_settings_split.bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  PREFS="${SETTINGS_PREFS_FILE:-${ROOT}/settings.json}"
  BASE="${ROOT}/machine-settings/base.json"
  POLICY_PATHS='[["hooks"],["env"],["deniedMcpServers"],["permissions","deny"],["permissions","ask"],["permissions","defaultMode"]]'
}

@test "policy paths are only in machine-settings" {
  run jq -e --argjson paths "${POLICY_PATHS}" \
    '. as $d | [$paths[] | select(. as $p | $d | getpath($p) == null)] | length == 0' "${BASE}"
  [ "${status}" -eq 0 ] || { echo "a policy path is missing from ${BASE}" >&2; return 1; }
  run jq -e --argjson paths "${POLICY_PATHS}" \
    '. as $d | [$paths[] | select(. as $p | $d | getpath($p) != null)] | length == 0' "${PREFS}"
  [ "${status}" -eq 0 ] || { echo "${PREFS} still holds a policy path" >&2; return 1; }
}

@test "permissions.allow is never in machine-settings" {
  run jq -e '.permissions.allow == null' "${BASE}"
  [ "${status}" -eq 0 ]
  local f
  for f in "${ROOT}"/machine-settings/hosts/*.json; do
    run jq -e '.permissions.allow == null' "${f}"
    [ "${status}" -eq 0 ] || { echo "${f} sets permissions.allow" >&2; return 1; }
  done
}

@test "no other key is in both files" {
  run jq -n -r --slurpfile a "${PREFS}" --slurpfile b "${BASE}" \
    '($a[0] | keys) - (($a[0] | keys) - ($b[0] | keys)) - ["permissions"] | join(",")'
  [ "${status}" -eq 0 ]
  [ -z "${output}" ] || { echo "keys in both files: ${output}" >&2; return 1; }
}
