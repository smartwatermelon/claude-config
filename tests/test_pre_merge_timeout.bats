#!/usr/bin/env bats
# Tests for prompt-size-scaled analysis timeout in pre-merge-review.sh
#
# Background: TIMEOUT_SECONDS used to be a flat 180s constant assigned at
# startup. Prompt size varies enormously between PRs and independently of
# anything knowable at that point, so the constant was either too small for
# big diffs or wastefully large for small ones. The observed failure was a
# 460-line PR whose 33,835-byte prompt timed out twice at 180s and completed
# comfortably at 420s.
#
# Fix: compute_effective_timeout() sizes the timeout from the assembled
# prompt's byte count — a 180s floor plus 10s per KB, clamped to a 900s
# ceiling — unless `git config review.preMergeTimeout` is set, in which case
# that value is honored verbatim and scaling is skipped entirely.
#
# Run: bats ~/.claude/tests/test_pre_merge_timeout.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/pre-merge-review.sh"

# Capture log_info output so tests can assert on which path was reported.
# Exported so the eval'd function can call them.
log_info() { echo "$*" >>"${LOG_FILE}"; }
export -f log_info
log_warn() { :; }
export -f log_warn
log_success() { :; }
export -f log_success
log_error() { :; }
export -f log_error

export LOG_FILE=""

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  LOG_FILE="${MOCK_DIR}/log.txt"
  : >"${LOG_FILE}"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Load only the named function from the script using sed range matching.
# Same helper pattern as test_pre_merge_nonblocking.bats: the sed range stops
# at the first bare `}` on its own line, so extracted functions must not
# contain an unindented nested closing brace.
_load_fn() {
  local fn_name="$1"
  local func_def
  func_def=$(sed -n "/^${fn_name}()/,/^}$/p" "${SCRIPT}")
  eval "${func_def}"
}

# Set up the constants the function reads, mirroring the script's own values,
# then load the function under test.
_setup_timeout_fn() {
  TIMEOUT_FLOOR_SECONDS=180
  TIMEOUT_PER_KB_SECONDS=10
  TIMEOUT_CEILING_SECONDS=900
  TIMEOUT_SECONDS="${TIMEOUT_FLOOR_SECONDS}"
  TIMEOUT_OVERRIDE="${1:-}"
  _load_fn compute_effective_timeout
}

# --- Constants match the calibration documented in the script ---

@test "constants: script defines floor 180, 10s/KB, ceiling 900" {
  grep -qE '^TIMEOUT_FLOOR_SECONDS=180$' "${SCRIPT}"
  grep -qE '^TIMEOUT_PER_KB_SECONDS=10$' "${SCRIPT}"
  grep -qE '^TIMEOUT_CEILING_SECONDS=900$' "${SCRIPT}"
}

# --- Scaled path ---

@test "scaled: zero-byte prompt yields the 180s floor" {
  _setup_timeout_fn ""
  compute_effective_timeout 0
  [[ "${TIMEOUT_SECONDS}" == "180" ]]
}

@test "scaled: sub-1KB prompt still yields the 180s floor" {
  _setup_timeout_fn ""
  compute_effective_timeout 900
  [[ "${TIMEOUT_SECONDS}" == "180" ]]
}

@test "scaled: exactly 1KB prompt yields floor plus one increment" {
  _setup_timeout_fn ""
  compute_effective_timeout 1024
  [[ "${TIMEOUT_SECONDS}" == "190" ]]
}

@test "scaled: the 33835-byte regression case clears 420s comfortably" {
  _setup_timeout_fn ""
  compute_effective_timeout 33835
  # 33835 / 1024 = 33 KB -> 180 + 330 = 510
  [[ "${TIMEOUT_SECONDS}" == "510" ]]
  # The whole point: strictly greater than both the old flat default and the
  # 420s value that was observed to work.
  ((TIMEOUT_SECONDS > 180))
  ((TIMEOUT_SECONDS > 420))
}

@test "scaled: mid-size prompt scales linearly" {
  _setup_timeout_fn ""
  compute_effective_timeout 20480
  # 20480 / 1024 = 20 KB -> 180 + 200 = 380
  [[ "${TIMEOUT_SECONDS}" == "380" ]]
}

@test "scaled: logs the scaling rationale" {
  _setup_timeout_fn ""
  compute_effective_timeout 33835
  grep -q "510s" "${LOG_FILE}"
  grep -q "scaled" "${LOG_FILE}"
}

# --- Ceiling ---

@test "ceiling: pathological prompt is clamped to 900s" {
  _setup_timeout_fn ""
  compute_effective_timeout 10000000
  [[ "${TIMEOUT_SECONDS}" == "900" ]]
}

@test "ceiling: prompt just past the ceiling boundary is clamped" {
  _setup_timeout_fn ""
  # 900s ceiling is reached at 72 KB; 73 KB would compute 910.
  compute_effective_timeout $((73 * 1024))
  [[ "${TIMEOUT_SECONDS}" == "900" ]]
}

@test "ceiling: prompt at exactly the ceiling boundary is not clamped early" {
  _setup_timeout_fn ""
  compute_effective_timeout $((72 * 1024))
  [[ "${TIMEOUT_SECONDS}" == "900" ]]
  # Reported as a plain scaled value, not a clamp, since 180 + 720 == 900.
  ! grep -q "clamped" "${LOG_FILE}"
}

@test "ceiling: clamped path says so in the log" {
  _setup_timeout_fn ""
  compute_effective_timeout 10000000
  grep -q "clamped" "${LOG_FILE}"
}

# --- Explicit override path ---

@test "override: configured value is honored verbatim" {
  _setup_timeout_fn "420"
  compute_effective_timeout 33835
  [[ "${TIMEOUT_SECONDS}" == "420" ]]
}

@test "override: a value below the floor is still honored (no clamping up)" {
  _setup_timeout_fn "60"
  compute_effective_timeout 33835
  [[ "${TIMEOUT_SECONDS}" == "60" ]]
}

@test "override: a value above the ceiling is still honored (no clamping down)" {
  _setup_timeout_fn "3600"
  compute_effective_timeout 10000000
  [[ "${TIMEOUT_SECONDS}" == "3600" ]]
}

@test "override: logs that the override path was taken" {
  _setup_timeout_fn "420"
  compute_effective_timeout 33835
  grep -q "explicit override" "${LOG_FILE}"
  grep -q "review.preMergeTimeout" "${LOG_FILE}"
}

# --- Wiring: the function is actually called with the real prompt size ---

@test "wiring: compute_effective_timeout is called with PROMPT_SIZE" {
  grep -qE '^compute_effective_timeout "\$\{PROMPT_SIZE\}"$' "${SCRIPT}"
}

@test "wiring: the call site follows the prompt-size log line" {
  local prompt_line call_line
  prompt_line=$(grep -n 'Prompt size: ' "${SCRIPT}" | head -1 | cut -d: -f1)
  call_line=$(grep -n '^compute_effective_timeout ' "${SCRIPT}" | head -1 | cut -d: -f1)
  ((call_line > prompt_line))
}

@test "wiring: the git config read is an override, not a default of 180" {
  # Guards against a regression to `... || echo "180"`, which would make the
  # override path indistinguishable from the unset case.
  grep -qE '^TIMEOUT_OVERRIDE=.*review\.preMergeTimeout.*echo ""\)$' "${SCRIPT}"
}

# --- Timeout message distinguishes infrastructure failure from a finding ---

@test "message: timeout error states no opinion was rendered" {
  grep -q "rendered NO opinion" "${SCRIPT}"
}

@test "message: timeout error names it an infrastructure failure" {
  grep -q "infrastructure failure, not a review finding" "${SCRIPT}"
}

@test "message: timeout error surfaces the config key to the operator" {
  grep -q 'git config --global review.preMergeTimeout' "${SCRIPT}"
}

@test "message: timeout error tells the operator to re-run the merge" {
  grep -qi "Re-run the merge" "${SCRIPT}"
}

@test "message: timeout error warns the override bypasses the ceiling (#355)" {
  # The suggested value is TIMEOUT_SECONDS * 2. At the ceiling that is 1800s,
  # double the documented cap -- an operator following the instruction should
  # be told the override leaves the ceiling behind, not just that scaling is
  # skipped.
  # Assert on the rendered message block, not on single-line layout: the
  # sentence wraps across log_error calls, so a one-line regex is brittle.
  local msg
  msg=$(grep -A4 'honored verbatim' "${SCRIPT}" | tr '\n' ' ')
  [[ "${msg}" == *"scaling"* ]] || {
    echo "override note does not mention scaling: ${msg}"
    return 1
  }
  [[ "${msg}" == *"ceiling"* ]] || {
    echo "override note does not warn that the ceiling is bypassed: ${msg}"
    return 1
  }
}
