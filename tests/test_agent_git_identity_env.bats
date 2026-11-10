#!/usr/bin/env bats
# Agent sessions include ~/.config/git/agent-identity (dotfiles) as command-scope git config.
# That file gives commits the App bot identity in App-routed repos only.

bats_require_minimum_version 1.5.0

setup() {
  BASE="${BASE_FILE:-${BATS_TEST_DIRNAME}/../machine-settings/base.json}"
}

@test "base.json env includes the agent git identity file" {
  run jq -r '.env | [.GIT_CONFIG_COUNT, .GIT_CONFIG_KEY_0, .GIT_CONFIG_VALUE_0] | join(" ")' "${BASE}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "1 include.path ~/.config/git/agent-identity" ]
}

@test "no other GIT_CONFIG_KEY_n entries outside the count" {
  run jq -e '.env | keys | map(select(test("^GIT_CONFIG_(KEY|VALUE)_[1-9]"))) | length == 0' "${BASE}"
  [ "${status}" -eq 0 ]
}
