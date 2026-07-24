#!/usr/bin/env bats
# Tests for the parse_verdict() helper in hooks/run-review.sh.
#
# Why this exists: the review gate previously matched verdicts with a literal
# `grep "VERDICT: PASS"`, which failed to recognize markdown-emphasized verdicts
# such as `VERDICT: **PASS**` that the (non-deterministic) reviewer models emit.
# An unparseable PASS fell through to the else branch and blocked the commit
# (fail-closed on a genuine pass). parse_verdict() normalizes emphasis, case,
# and spacing while preserving the original "PASS anywhere wins" precedence and
# the fail-closed "" result for genuinely unparseable output.
#
# Run: bats tests/test_parse_verdict.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
  # Source only the parse_verdict function (the script as a whole executes a
  # full review when run). The function body's closing brace is at column 0.
  eval "$(sed -n '/^parse_verdict() {/,/^}/p' "${SCRIPT}")"
}

@test "plain PASS" {
  run parse_verdict "VERDICT: PASS"
  [ "${output}" = "PASS" ]
}

@test "bold PASS (the original regression)" {
  run parse_verdict "VERDICT: **PASS**"
  [ "${output}" = "PASS" ]
}

@test "bold PASS with no space after colon" {
  run parse_verdict "VERDICT:**PASS**"
  [ "${output}" = "PASS" ]
}

@test "backtick-wrapped PASS" {
  run parse_verdict 'VERDICT: `PASS`'
  [ "${output}" = "PASS" ]
}

@test "underscore-italic PASS" {
  run parse_verdict "VERDICT: _PASS_"
  [ "${output}" = "PASS" ]
}

@test "lowercase verdict/pass" {
  run parse_verdict "verdict: pass"
  [ "${output}" = "PASS" ]
}

@test "plain FAIL" {
  run parse_verdict "VERDICT: FAIL"
  [ "${output}" = "FAIL" ]
}

@test "bold FAIL (chunked path was fail-open here)" {
  run parse_verdict "VERDICT: **FAIL**"
  [ "${output}" = "FAIL" ]
}

@test "transient FAIL with paren still normalizes to FAIL" {
  run parse_verdict "VERDICT: FAIL (timeout)"
  [ "${output}" = "FAIL" ]
}

@test "Revise maps to REVISE token" {
  run parse_verdict "VERDICT: Revise"
  [ "${output}" = "REVISE" ]
}

@test "verdict embedded in a multi-line review body" {
  run parse_verdict $'# Code Review\n\nSome analysis here.\n\nVERDICT: **PASS**\n\nNo blocking issues.'
  [ "${output}" = "PASS" ]
}

@test "PASS wins when it appears (precedence preserved)" {
  # Pathological output mentioning FAIL in prose but verdict is PASS.
  run parse_verdict $'I nearly wrote VERDICT: FAIL but reconsidered.\nVERDICT: PASS'
  [ "${output}" = "PASS" ]
}

@test "unparseable output yields empty string (fail-closed)" {
  run parse_verdict "This review has no verdict line at all."
  [ "${output}" = "" ]
}

@test "empty input yields empty string" {
  run parse_verdict ""
  [ "${output}" = "" ]
}
