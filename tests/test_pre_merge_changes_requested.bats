#!/usr/bin/env bats
# Tests for the CHANGES_REQUESTED hard block in pre-merge-review.sh
#
# Issue #27 (2026-01-20): the hook was delegating review state enforcement to
# Claude, which rationalized CHANGES_REQUESTED reviews as "nice-to-have" and
# allowed merges to proceed.
#
# Fix: add a hard shell-level block BEFORE Claude is invoked. If the GitHub
# reviewDecision is CHANGES_REQUESTED, or if any individual review has state
# CHANGES_REQUESTED, exit 1 immediately without running Claude.
#
# Run: bats ~/.claude/tests/test_pre_merge_changes_requested.bats

SCRIPT="${HOME}/.claude/hooks/pre-merge-review.sh"

# PR JSON with reviewDecision = CHANGES_REQUESTED
JSON_CHANGES_REQUESTED='{"number":640,"title":"fix: something","reviewDecision":"CHANGES_REQUESTED","reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","body":"needs work","submittedAt":"2026-01-20T18:00:00Z"}],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

# PR JSON with reviewDecision = APPROVED
JSON_APPROVED='{"number":640,"title":"fix: something","reviewDecision":"APPROVED","reviews":[{"author":{"login":"alice"},"state":"APPROVED","body":"lgtm","submittedAt":"2026-01-20T18:00:00Z"}],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

# PR JSON with no reviewDecision but individual CHANGES_REQUESTED review
JSON_NO_DECISION_CHANGES='{"number":640,"title":"fix: something","reviewDecision":"NONE","reviews":[{"author":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"nope","submittedAt":"2026-01-20T18:00:00Z"}],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

# PR JSON with a dismissed review (should NOT block)
JSON_DISMISSED='{"number":640,"title":"fix: something","reviewDecision":"APPROVED","reviews":[{"author":{"login":"carol"},"state":"DISMISSED","body":"was blocked, now dismissed","submittedAt":"2026-01-20T18:00:00Z"},{"author":{"login":"alice"},"state":"APPROVED","body":"lgtm","submittedAt":"2026-01-20T19:00:00Z"}],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

# PR JSON with no reviews at all
JSON_NO_REVIEWS='{"number":640,"title":"fix: something","reviewDecision":"NONE","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

# PR JSON where a reviewer requested changes then later approved the same PR.
# The `reviews` field contains both entries; only the latest (APPROVED) counts.
# reviewDecision is APPROVED (GitHub's rollup), and the block must NOT trigger.
JSON_REREVIEWED='{"number":640,"title":"fix: something","reviewDecision":"APPROVED","reviews":[{"author":{"login":"alice"},"state":"CHANGES_REQUESTED","body":"needs work","submittedAt":"2026-01-20T18:00:00Z"},{"author":{"login":"alice"},"state":"APPROVED","body":"lgtm now","submittedAt":"2026-01-20T20:00:00Z"}],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock claude CLI — should NEVER be invoked by CHANGES_REQUESTED tests.
  # If called, it creates a sentinel file so tests can detect it.
  cat >"${MOCK_DIR}/claude" <<CLAUDE_EOF
#!/usr/bin/env bash
touch "${MOCK_DIR}/claude_was_called"
echo "ERROR: claude CLI was called unexpectedly in CHANGES_REQUESTED test" >&2
exit 1
CLAUDE_EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  # Mock merge-lock.sh — always authorized so we test only the review state check.
  cat >"${MOCK_DIR}/merge-lock.sh" <<'LOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]]; then
  exit 0
fi
LOCK_EOF
  chmod +x "${MOCK_DIR}/merge-lock.sh"
  export MOCK_LOCK="${MOCK_DIR}/merge-lock.sh"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

_run_with_json() {
  local pr_json="$1"
  env HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    bash -c "
      export HOME='${MOCK_DIR}/home'
      export CLAUDE_CLI='${MOCK_DIR}/claude'
      mkdir -p \"\${HOME}/.claude/hooks\"
      cp '${MOCK_LOCK}' \"\${HOME}/.claude/hooks/merge-lock.sh\"
      chmod +x \"\${HOME}/.claude/hooks/merge-lock.sh\"
      cat >\"${MOCK_DIR}/gh\" <<'GHEOF'
#!/usr/bin/env bash
if [[ \"\$1\" == \"pr\" && \"\$2\" == \"view\" ]]; then
  echo '${pr_json}'
  exit 0
fi
echo \"[]\"
exit 0
GHEOF
      chmod +x \"${MOCK_DIR}/gh\"
      '${SCRIPT}' pr merge 640
    " 2>&1
}

# --- reviewDecision == CHANGES_REQUESTED ---

@test "reviewDecision CHANGES_REQUESTED: exits with code 1" {
  run _run_with_json "${JSON_CHANGES_REQUESTED}"
  [[ "${status}" -eq 1 ]]
}

@test "reviewDecision CHANGES_REQUESTED: output mentions MERGE BLOCKED" {
  run _run_with_json "${JSON_CHANGES_REQUESTED}"
  [[ "${output}" == *"MERGE BLOCKED"* ]]
}

@test "reviewDecision CHANGES_REQUESTED: output mentions CHANGES_REQUESTED" {
  run _run_with_json "${JSON_CHANGES_REQUESTED}"
  [[ "${output}" == *"CHANGES_REQUESTED"* ]]
}

@test "reviewDecision CHANGES_REQUESTED: stdout contains single-line summary (visible in Bash tool)" {
  run _run_with_json "${JSON_CHANGES_REQUESTED}"
  [[ "${output}" == *"🛑 MERGE BLOCKED"* ]]
}

@test "reviewDecision CHANGES_REQUESTED: exits before running claude CLI" {
  _run_with_json "${JSON_CHANGES_REQUESTED}" || true
  [[ ! -f "${MOCK_DIR}/claude_was_called" ]]
}

# --- individual review CHANGES_REQUESTED with no reviewDecision rollup ---

@test "individual CHANGES_REQUESTED review with NONE decision: exits with code 1" {
  run _run_with_json "${JSON_NO_DECISION_CHANGES}"
  [[ "${status}" -eq 1 ]]
}

@test "individual CHANGES_REQUESTED review: output lists reviewer login" {
  run _run_with_json "${JSON_NO_DECISION_CHANGES}"
  [[ "${output}" == *"bob"* ]]
}

@test "individual CHANGES_REQUESTED review: exits before running claude CLI" {
  _run_with_json "${JSON_NO_DECISION_CHANGES}" || true
  [[ ! -f "${MOCK_DIR}/claude_was_called" ]]
}

# --- DISMISSED reviews should NOT block ---

@test "DISMISSED review: does not block on dismissed review (passes through)" {
  # A dismissed CHANGES_REQUESTED review should not block — it is resolved.
  # This test verifies we don't misread DISMISSED as CHANGES_REQUESTED.
  # The script will proceed past the check; claude mock exits 1 (expected).
  run _run_with_json "${JSON_DISMISSED}"
  # Should NOT see the MERGE BLOCKED message — same assertion as the APPROVED case.
  [[ "${output}" != *"MERGE BLOCKED"* ]]
}

# --- APPROVED and no-review cases should not block ---

@test "reviewDecision APPROVED: does not block" {
  run _run_with_json "${JSON_APPROVED}"
  # The block emits "MERGE BLOCKED" — check that message is absent.
  # (Don't check for "CHANGES_REQUESTED" itself: the claude mock error message
  #  also contains that string and would cause a false positive.)
  [[ "${output}" != *"MERGE BLOCKED"* ]]
}

@test "no reviews at all: does not block on review state" {
  run _run_with_json "${JSON_NO_REVIEWS}"
  [[ "${output}" != *"MERGE BLOCKED"* ]]
}

# --- Re-reviewed: same reviewer requests then approves (must NOT block) ---

@test "re-reviewed: reviewer who approved after requesting changes does not block" {
  # The `reviews` array contains both the old CHANGES_REQUESTED and new APPROVED
  # entry for the same author. Only the latest review per author counts.
  # If the belt-and-suspenders check uses raw `.reviews` instead of deduplicating
  # by author, this test will fail (false positive block on a legitimately approved PR).
  run _run_with_json "${JSON_REREVIEWED}"
  [[ "${output}" != *"MERGE BLOCKED"* ]]
}
