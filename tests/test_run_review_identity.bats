#!/usr/bin/env bats
# Tests that run-review.sh writes identity fields to the review log header.
#
# Root cause: ~/.claude/last-review-result.log had no repo/branch/commit
# fields, making cross-repo contamination undetectable (incident 2026-03-08).
#
# Run: bats ~/.claude/tests/test_run_review_identity.bats

setup() {
  # Create a temp git repo so git commands work
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  touch "${TMPDIR_TEST}/init.txt"
  git -C "${TMPDIR_TEST}" add init.txt
  # Use GIT_CONFIG_GLOBAL=/dev/null to skip global hooks (core.hooksPath) in the temp repo
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "init"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  # Mock claude CLI: consume stdin, emit a minimal PASS verdict
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "VERDICT: PASS"
echo "No blocking issues found."
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Helper: run review script from within the temp repo with a tiny diff on stdin
run_review() {
  cd "${TMPDIR_TEST}" || exit
  printf 'diff --git a/foo.js b/foo.js\nindex 0000000..1234567 100644\n--- a/foo.js\n+++ b/foo.js\n@@ -0,0 +1 @@\n+const x = 1;\n' \
    | REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
      bash "${HOME}/.claude/hooks/run-review.sh"
}

@test "log header contains 'repo:' field pointing to the test repo root" {
  run_review || true
  grep -q "^repo: ${TMPDIR_TEST}$" "${EXPECTED_LOG}"
}

@test "log header contains 'branch:' field" {
  run_review || true
  grep -q "^branch: test-branch$" "${EXPECTED_LOG}"
}

@test "log header contains 'commit:' field with a short SHA" {
  run_review || true
  grep -qE "^commit: [0-9a-f]{7,}$" "${EXPECTED_LOG}"
}

@test "log header fields appear before VERDICT output" {
  run_review || true
  repo_line=$(grep -n "^repo:" "${EXPECTED_LOG}" | head -1 | cut -d: -f1)
  verdict_line=$(grep -n "CODE REVIEWER" "${EXPECTED_LOG}" | head -1 | cut -d: -f1)
  [[ -n "${repo_line}" ]]
  [[ -n "${verdict_line}" ]]
  [[ "${repo_line}" -lt "${verdict_line}" ]]
}

@test "log is written inside .git/ by default (no REVIEW_LOG override)" {
  cd "${TMPDIR_TEST}"
  printf 'diff --git a/foo.js b/foo.js\nindex 0000000..1234567 100644\n--- a/foo.js\n+++ b/foo.js\n@@ -0,0 +1 @@\n+const x = 1;\n' \
    | CLAUDE_CLI="${CLAUDE_CLI}" \
      bash "${HOME}/.claude/hooks/run-review.sh" || true
  [[ -f "${TMPDIR_TEST}/.git/last-review-result.log" ]]
}

@test "global pointer file is updated at ~/.claude/last-review-result.log" {
  run_review || true
  [[ -f "${HOME}/.claude/last-review-result.log" ]]
  grep -q "${TMPDIR_TEST}" "${HOME}/.claude/last-review-result.log"
}
