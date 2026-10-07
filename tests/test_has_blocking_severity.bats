#!/usr/bin/env bats
# Tests for the has_blocking_severity() helper in hooks/run-review.sh.
#
# Why this exists: all five severity gates previously matched with a literal
# `grep -q "SEVERITY: BLOCKING"` — case-sensitive and space-exact — while
# parse_verdict() had already been made tolerant of markdown emphasis, case,
# and spacing. Reviewer models are non-deterministic, so a prose-heavy prompt
# emitting `**SEVERITY:** BLOCKING`, `Severity: Blocking`, or a double space
# slipped the gate: a real blocking defect was committed with exit 0
# (fail-OPEN on a genuine block — the opposite and more dangerous direction of
# the parse_verdict regression). These cases pin both halves of the corpus:
# the true positives that must keep matching, and the outputs that must stay
# non-blocking after the pattern was loosened.
#
# Run: bats tests/test_has_blocking_severity.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
  # Source only the has_blocking_severity function (the script as a whole
  # executes a full review when run). The function body's closing brace is at
  # column 0.
  eval "$(sed -n '/^has_blocking_severity() {/,/^}/p' "${SCRIPT}")"
}

# --- Must match: the plain form and every variant that slipped the old gate ---

@test "plain SEVERITY: BLOCKING" {
  run has_blocking_severity "SEVERITY: BLOCKING"
  [ "${status}" -eq 0 ]
}

@test "bold key: **SEVERITY:** BLOCKING (the original leak)" {
  run has_blocking_severity "**SEVERITY:** BLOCKING"
  [ "${status}" -eq 0 ]
}

@test "bold whole line: **SEVERITY: BLOCKING**" {
  run has_blocking_severity "**SEVERITY: BLOCKING**"
  [ "${status}" -eq 0 ]
}

@test "bold key with separate colon: - **SEVERITY**: BLOCKING" {
  run has_blocking_severity "- **SEVERITY**: BLOCKING"
  [ "${status}" -eq 0 ]
}

@test "mixed case: Severity: Blocking" {
  run has_blocking_severity "Severity: Blocking"
  [ "${status}" -eq 0 ]
}

@test "lowercase: severity: blocking" {
  run has_blocking_severity "severity: blocking"
  [ "${status}" -eq 0 ]
}

@test "two spaces after the colon" {
  run has_blocking_severity "SEVERITY:  BLOCKING"
  [ "${status}" -eq 0 ]
}

@test "no space after the colon" {
  run has_blocking_severity "SEVERITY:BLOCKING"
  [ "${status}" -eq 0 ]
}

@test "tab after the colon" {
  run has_blocking_severity "$(printf 'SEVERITY:\tBLOCKING')"
  [ "${status}" -eq 0 ]
}

@test "backtick-wrapped SEVERITY: BLOCKING" {
  run has_blocking_severity 'SEVERITY: `BLOCKING`'
  [ "${status}" -eq 0 ]
}

@test "underscore-italic SEVERITY: BLOCKING" {
  run has_blocking_severity "_SEVERITY: BLOCKING_"
  [ "${status}" -eq 0 ]
}

@test "severity embedded in a full review body" {
  run has_blocking_severity $'VERDICT: FAIL\n\nISSUE: Hardcoded credential\nSEVERITY: BLOCKING\nLOCATION: foo.sh:2\nDETAILS: Remove it.'
  [ "${status}" -eq 0 ]
}

@test "severity embedded in a Revise body (Revise is a FAIL synonym)" {
  run has_blocking_severity $'VERDICT: Revise\n\nISSUE: Hardcoded secret\n**SEVERITY:** BLOCKING\nLOCATION: foo.sh:2'
  [ "${status}" -eq 0 ]
}

# --- Must NOT match: outputs that must stay non-blocking ---

@test "SEVERITY: WARNING does not block" {
  run has_blocking_severity "SEVERITY: WARNING"
  [ "${status}" -ne 0 ]
}

@test "bolded WARNING does not block (loosening must not over-match)" {
  run has_blocking_severity "**SEVERITY:** WARNING"
  [ "${status}" -ne 0 ]
}

@test "a clean PASS body does not block" {
  run has_blocking_severity $'VERDICT: PASS\n\nNo blocking issues found.'
  [ "${status}" -ne 0 ]
}

@test "transient agent-error FAIL has no severity and does not block" {
  # Preserves the adversarial-reviewer gate's non-blocking treatment of
  # infrastructure failures (#172).
  run has_blocking_severity "VERDICT: FAIL (agent error: 1)"
  [ "${status}" -ne 0 ]
}

@test "transient timeout FAIL has no severity and does not block" {
  run has_blocking_severity "VERDICT: FAIL (timeout)"
  [ "${status}" -ne 0 ]
}

@test "SEVERITY: NON_BLOCKING_ISSUE does not block" {
  # Underscores are stripped, leaving NONBLOCKING; the pattern requires
  # BLOCKING to follow the colon directly, so this correctly does not match.
  run has_blocking_severity "SEVERITY: NON_BLOCKING_ISSUE"
  [ "${status}" -ne 0 ]
}

@test "the word blocking in prose without the key does not block" {
  run has_blocking_severity "No blocking issues. SEVERITY levels used: WARNING."
  [ "${status}" -ne 0 ]
}

@test "empty input does not block" {
  run has_blocking_severity ""
  [ "${status}" -ne 0 ]
}

# --- Documented behavior: substring matching, unchanged from the literal grep ---

@test "prose containing the key still matches (fails closed, as before)" {
  # The replaced `grep -q "SEVERITY: BLOCKING"` matched this too. Kept
  # deliberately: for a gate, a false block is the safe direction, and
  # changing it here would be a behavior change beyond the fix.
  run has_blocking_severity "This is not a SEVERITY: BLOCKING issue."
  [ "${status}" -eq 0 ]
}
