#!/usr/bin/env bats
# Tests for ~/.claude/scripts/status-line.sh
#
# The context segment was added after an infra session compacted three times in
# under three hours (2026-09-03). The warm-start floor had grown 45k -> 89k
# against a 200k autoCompactWindow, mostly from an 890-tool MCP connector
# listing re-injected at every restart. Nothing surfaced that while it was
# happening; it took a manual /context run afterwards to find.
#
# WHAT THESE TESTS ARE DEFENDING (the tripwires that matter):
#
#   1. The cold-cache marker MUST survive `warm: false`. The first
#      implementation read it with `.prompt_cache.warm // empty`, and jq's
#      alternative operator treats `false` as empty -- so the single value the
#      marker exists to report was silently swallowed. That bug passed a
#      warm-cache test and a missing-key test. "cold cache marker renders on
#      warm=false" is the canary: it fails if anyone reintroduces `//` here.
#
#   2. Degradation MUST stay silent, never fatal. This script is shared across
#      machines and Claude accounts through claude-config, so it runs against
#      older CLI builds that omit context_window and prompt_cache entirely, and
#      against jq 1.7 (asiago) as well as 1.8 (arich-mac). Missing fields,
#      an empty object, and outright malformed stdin must all still print a
#      usable line and exit 0 -- a status line that errors is worse than one
#      that says less.
#
#   3. No invented numbers. used_percentage is consumed as given by the
#      harness, never recomputed locally. Deriving it would reintroduce the
#      chars-per-token estimation error this whole segment replaced.
#
# Run: bats ~/.claude/tests/test_status_line_context.bats

SL="${BATS_TEST_DIRNAME}/../scripts/status-line.sh"

# Assertions strip ANSI colour inline (sed) so they test content, not escapes.

@test "renders context tokens, window size and percentage" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":26900,\"context_window_size\":200000,\"used_percentage\":13.45}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ctx 27k/200k 13%"* ]]
}

@test "1M window renders as 1M, not 1000k" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":89215,\"context_window_size\":1000000,\"used_percentage\":8.9}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ctx 89k/1M 9%"* ]]
  [[ "${output}" != *"1000k"* ]]
}

# THE CANARY: jq's `//` treats false as empty. If someone "simplifies" the
# has()/tostring lookup back to `.prompt_cache.warm // empty`, this fails.
@test "cold cache marker renders on warm=false" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":166000,\"context_window_size\":200000,\"used_percentage\":83},\"prompt_cache\":{\"warm\":false}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"cold"* ]]
}

@test "warm cache prints no marker" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":20000,\"context_window_size\":200000,\"used_percentage\":10},\"prompt_cache\":{\"warm\":true}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"cold"* ]]
}

@test "missing prompt_cache key prints no marker and does not fail" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":50000,\"context_window_size\":200000,\"used_percentage\":25}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"ctx 50k"* ]]
  [[ "${output}" != *"cold"* ]]
}

# Older CLI builds omit context_window entirely. The line must still render.
@test "old build without context_window still prints a usable line" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/tmp"* ]]
  [[ "${output}" != *"ctx"* ]]
}

@test "falls back to top-level cwd when workspace is absent" {
  run bash -c "printf '%s' '{\"cwd\":\"/etc\"}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"/etc"* ]]
}

@test "empty JSON object exits 0" {
  run bash -c "printf '%s' '{}' | bash '${SL}'"
  [ "${status}" -eq 0 ]
}

@test "malformed stdin exits 0 rather than erroring" {
  run bash -c "printf '%s' 'not json at all' | bash '${SL}'"
  [ "${status}" -eq 0 ]
}

# The threshold compare must round, not truncate. With %d, 74.6 displays as
# "75%" while comparing as 74 -- the colour contradicts the number beside it.
@test "pressure colour rounds at the threshold rather than truncating" {
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":149200,\"context_window_size\":200000,\"used_percentage\":74.6}}' | bash '${SL}'"
  [ "${status}" -eq 0 ]
  # Displays 75% -> must be red (31m), not green (32m) on the ctx segment.
  [[ "${output}" == *"75%"* ]]
  [[ "${output}" == *$'\033[31mctx'* ]]
}

@test "percentage is taken from the harness, never recomputed" {
  # used_percentage deliberately disagrees with tokens/size. The script must
  # print the harness value (42%), not its own division (10%).
  run bash -c "printf '%s' '{\"workspace\":{\"current_dir\":\"/tmp\"},\"context_window\":{\"total_input_tokens\":20000,\"context_window_size\":200000,\"used_percentage\":42}}' | bash '${SL}' | sed -e 's/\x1b\[[0-9;]*m//g'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"42%"* ]]
}
