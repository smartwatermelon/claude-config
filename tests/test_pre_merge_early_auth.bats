#!/usr/bin/env bats
# Tests for the early merge-lock authorization check in pre-merge-review.sh
#
# Root cause: when pre-merge-review.sh spawned the claude CLI, the Claude Code
# Bash tool stopped surfacing output in the tool result (a known interaction
# between nested claude processes and the Bash tool's PTY capture). The script
# would silently exit with code 1 — no explanation, no instructions, just an
# exit code.
#
# Fix: check merge-lock authorization BEFORE running the claude CLI. A fast
# failure (< 1s, before any claude invocation) produces visible output.
#
# Run: bats ~/.claude/tests/test_pre_merge_early_auth.bats

SCRIPT="${HOME}/.claude/hooks/pre-merge-review.sh"
VALID_JSON='{"number":59,"title":"test PR","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock gh that returns valid PR JSON for `pr view` and empty for other calls
  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  echo '${VALID_JSON}'
  exit 0
fi
echo "[]"
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Mock claude CLI — must exist and be executable for preflight to pass.
  # The merge-lock check runs BEFORE claude is invoked; if the lock check fails
  # (not authorized), claude is never called. Set CLAUDE_CLI explicitly so the
  # script finds this mock regardless of the mock HOME path.
  cat >"${MOCK_DIR}/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
# Should never be invoked when merge-lock is not authorized.
echo "ERROR: claude CLI was called unexpectedly in auth test" >&2
exit 1
CLAUDE_EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  # Mock merge-lock.sh — controls authorization state
  MOCK_LOCK="${MOCK_DIR}/merge-lock.sh"
  export MOCK_LOCK
  mkdir -p "${MOCK_DIR}/hooks"

  # Default: NOT authorized (tests can override)
  cat >"${MOCK_LOCK}" <<'LOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]]; then
  echo "Not authorized"
  exit 1
fi
LOCK_EOF
  chmod +x "${MOCK_LOCK}"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

_run_with_mock_lock() {
  env HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    bash -c "
      export HOME='${MOCK_DIR}/home'
      export CLAUDE_CLI='${CLAUDE_CLI}'
      mkdir -p \"\${HOME}/.claude/hooks\"
      cp '${MOCK_LOCK}' \"\${HOME}/.claude/hooks/merge-lock.sh\"
      chmod +x \"\${HOME}/.claude/hooks/merge-lock.sh\"
      '${SCRIPT}' pr merge 59
    " 2>&1
}

@test "not authorized: exits with code 1" {
  run _run_with_mock_lock

  [[ "${status}" -eq 1 ]]
}

@test "not authorized: output contains MERGE AUTHORIZATION REQUIRED" {
  run _run_with_mock_lock

  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"MERGE AUTHORIZATION REQUIRED"* ]]
}

@test "not authorized: output contains the merge-lock authorize command" {
  run _run_with_mock_lock

  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"merge-lock.sh authorize"* ]]
}

@test "not authorized: output contains the retry instruction" {
  run _run_with_mock_lock

  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"gh pr merge 59"* ]]
}

@test "not authorized: stdout contains the single-line summary (visible in Bash tool)" {
  # The stdout message is written so Claude Code's Bash tool always surfaces it.
  # If only stderr is written, the tool result may be silent after claude CLI runs.
  run _run_with_mock_lock

  [[ "${status}" -eq 1 ]]
  # The 🛑 prefix is on stdout (printf without >&2)
  [[ "${output}" == *"🛑 MERGE AUTHORIZATION REQUIRED"* ]]
}

@test "not authorized: exits before running claude CLI" {
  # Sentinel: if claude CLI is invoked, it writes to a file. If the file exists
  # after the run, the early-check failed to short-circuit before claude.
  local sentinel="${MOCK_DIR}/claude_was_called"
  local sentinel_claude="${MOCK_DIR}/sentinel_claude"
  cat >"${sentinel_claude}" <<EOF
#!/usr/bin/env bash
touch '${sentinel}'
exit 0
EOF
  chmod +x "${sentinel_claude}"

  env HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    bash -c "
      export HOME='${MOCK_DIR}/home'
      export CLAUDE_CLI='${sentinel_claude}'
      mkdir -p \"\${HOME}/.claude/hooks\"
      cp '${MOCK_LOCK}' \"\${HOME}/.claude/hooks/merge-lock.sh\"
      chmod +x \"\${HOME}/.claude/hooks/merge-lock.sh\"
      '${SCRIPT}' pr merge 59
    " 2>&1 || true

  # Claude should NOT have been called
  [[ ! -f "${sentinel}" ]]
}
