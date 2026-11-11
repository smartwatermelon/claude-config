#!/usr/bin/env bats
# Split guard: policy keys live in machine-settings/base.json, not in the
# preferences file (user-settings/base.json, built into ~/.claude/settings.json).
# Hooks merge across scopes, so a key in both runs twice.
#
# SETTINGS_PREFS_FILE overrides the preferences file, so the guard can be
# checked against a known-bad copy.
#
# Run: bats ~/Developer/claude-config/tests/test_settings_split.bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/.."
  PREFS="${SETTINGS_PREFS_FILE:-${ROOT}/user-settings/base.json}"
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
  local f
  for f in "${ROOT}"/user-settings/hosts/*.json; do
    run jq -e --argjson paths "${POLICY_PATHS}" \
      '. as $d | [$paths[] | select(. as $p | $d | getpath($p) != null)] | length == 0' "${f}"
    [ "${status}" -eq 0 ] || { echo "${f} holds a policy path" >&2; return 1; }
  done
}

# autoMode is read at user scope; the docs do not list --settings for it (dev-env#236).
@test "autoMode is only in user-settings" {
  run jq -e 'has("autoMode")' "${PREFS}"
  [ "${status}" -eq 0 ] || { echo "${PREFS} lacks autoMode" >&2; return 1; }
  local f
  for f in "${BASE}" "${ROOT}"/machine-settings/hosts/*.json; do
    run jq -e 'has("autoMode") | not' "${f}"
    [ "${status}" -eq 0 ] || { echo "${f} sets autoMode" >&2; return 1; }
  done
}

# The build output and its local overlay (merged last, so it can unset the sandbox) live there.
@test "agents cannot edit ~/.config/claude-code" {
  run jq -e '.permissions.deny | index("Edit(~/.config/claude-code/**)") != null' "${BASE}"
  [ "${status}" -eq 0 ] || { echo "${BASE} lacks the Edit deny for ~/.config/claude-code" >&2; return 1; }
}

# Agents always run git -C <path>, so each "git push" ask rule needs a "git -C *" twin.
@test "every git push ask rule also covers git -C" {
  run jq -e '.permissions.ask as $a | [$a[] | select(startswith("Bash(git push "))
    | sub("^Bash\\(git push "; "Bash(git -C * push ") | select(. as $t | $a | index($t) == null)] | length == 0' "${BASE}"
  [ "${status}" -eq 0 ] || { echo "${BASE}: a git push ask rule has no git -C twin" >&2; return 1; }
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
