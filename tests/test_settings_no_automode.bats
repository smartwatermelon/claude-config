#!/usr/bin/env bats
# Leak guard for settings.json: no top-level autoMode key.
#
# settings.json ships to every machine through the ~/.claude symlink, but
# /auto-mode-setup and the /permissions Auto mode tab write autoMode into it.
# autoMode describes one machine's environment, so it belongs in
# ~/.config/claude-code/machine-settings.json, loaded with --settings.
# See README.md "Shared vs machine settings".
#
# SETTINGS_FILE overrides the file under test, so the guard can be checked
# against a known-bad copy without touching the real one.
#
# Run: bats ~/Developer/claude-config/tests/test_settings_no_automode.bats

bats_require_minimum_version 1.5.0

setup() {
  SETTINGS="${SETTINGS_FILE:-${BATS_TEST_DIRNAME}/../settings.json}"
}

@test "settings.json is a JSON object" {
  run jq -e 'type == "object"' "${SETTINGS}"
  [ "${status}" -eq 0 ]
}

@test "settings.json has no top-level autoMode" {
  run jq -e 'has("autoMode")' "${SETTINGS}"
  if [ "${output}" = "true" ]; then
    echo "${SETTINGS} has a top-level autoMode key." >&2
    echo "settings.json ships to every machine; autoMode is per-machine." >&2
    echo "Move it to ~/.config/claude-code/machine-settings.json (see README.md, Shared vs machine settings)." >&2
    return 1
  fi
  [ "${output}" = "false" ]
}
