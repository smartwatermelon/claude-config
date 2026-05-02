#!/usr/bin/env bats
# Tests for the --message-file=PATH flag on hooks/run-review.sh.
#
# Why this exists: the pre-commit hook cannot read the in-progress commit
# message because git has not yet written it to COMMIT_EDITMSG at pre-commit
# time (per `man githooks`: pre-commit "is invoked before obtaining the
# proposed commit log message"). The PR #149 helper that reads COMMIT_EDITMSG
# in commit mode therefore returns the PREVIOUS commit's message — actively
# misleading developer intent.
#
# The --message-file=PATH flag lets the commit-msg hook (which receives the
# message file as $1) inject the actual message. This test suite verifies
# the flag works and the original behavior is preserved when it is absent.
#
# Run: bats ~/.claude/tests/test_run_review_message_file.bats

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  touch "${TMPDIR_TEST}/init.txt"
  git -C "${TMPDIR_TEST}" add init.txt
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  # Mock claude CLI: capture stdin (the prompt) to a file so tests can inspect
  # what the reviewer would have seen. Always emit a PASS verdict so the
  # script exits 0 and we can examine the captured prompt unconditionally.
  #
  # IMPORTANT: run-review.sh does a `claude --version` preflight before
  # reading its own stdin. The mock MUST short-circuit on --version (do
  # NOT consume stdin in that case), or it will drain the diff that
  # run-review.sh later expects to read via DIFF=$(cat). When the mock
  # eats the preflight's empty stdin and then the script's `cat` runs
  # against an already-closed fd, DIFF ends up empty and the script
  # exits with "No staged changes to review" — NOT what we want to test.
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PROMPT_CAPTURE="${MOCK_DIR}/captured-prompt.txt"
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
# --version preflight: don't touch stdin, just print a fake version.
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
done
# Real agent invocation: capture stdin (the prompt) and emit PASS.
cat >> "${PROMPT_CAPTURE}"
echo "VERDICT: PASS"
echo "No blocking issues found."
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Stage a tiny diff (one new file) so run-review.sh has something to feed
# the reviewer. Returns the diff on stdout.
_stage_tiny_diff() {
  echo "added line" > "${TMPDIR_TEST}/foo.txt"
  git -C "${TMPDIR_TEST}" add foo.txt
  git -C "${TMPDIR_TEST}" diff --cached
}

# Invoke run-review.sh in commit mode (default), feeding the staged diff
# on stdin. Pass any extra args through.
_run_review() {
  local diff
  diff=$(_stage_tiny_diff)
  cd "${TMPDIR_TEST}" || exit 1
  printf '%s\n' "${diff}" \
    | REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
      bash "${HOME}/.claude/hooks/run-review.sh" "$@"
}

@test "--message-file=PATH (equals form) injects the file contents into the review prompt" {
  echo "feat: deliberate test message via equals form" > "${MOCK_DIR}/msg.txt"
  _run_review --message-file="${MOCK_DIR}/msg.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  grep -q "DEVELOPER INTENT (commit message):" "${PROMPT_CAPTURE}"
  grep -q "feat: deliberate test message via equals form" "${PROMPT_CAPTURE}"
}

@test "--message-file PATH (space form) injects the file contents into the review prompt" {
  echo "feat: deliberate test message via space form" > "${MOCK_DIR}/msg.txt"
  _run_review --message-file "${MOCK_DIR}/msg.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  grep -q "DEVELOPER INTENT (commit message):" "${PROMPT_CAPTURE}"
  grep -q "feat: deliberate test message via space form" "${PROMPT_CAPTURE}"
}

@test "--message-file=PATH where PATH is missing falls back gracefully (no crash, no DEVELOPER INTENT header)" {
  # Sanity: file does NOT exist before invocation.
  [[ ! -e "${MOCK_DIR}/does-not-exist.txt" ]]
  _run_review --message-file="${MOCK_DIR}/does-not-exist.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  # The helper returns empty when the file is unreadable, AND the per-mode
  # fallback is bypassed because the flag was provided. So no header.
  ! grep -q "DEVELOPER INTENT (commit message):" "${PROMPT_CAPTURE}"
}

@test "--message-file=PATH where file is empty produces no DEVELOPER INTENT header" {
  : > "${MOCK_DIR}/empty.txt"
  _run_review --message-file="${MOCK_DIR}/empty.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  ! grep -q "DEVELOPER INTENT (commit message):" "${PROMPT_CAPTURE}"
}

@test "--message-file flag absent: existing COMMIT_EDITMSG behavior preserved" {
  # Seed COMMIT_EDITMSG with a known message. In real pre-commit this would
  # be the PREVIOUS commit's message (the bug); here we assert only that the
  # absent-flag code path still reads from COMMIT_EDITMSG verbatim.
  printf 'previous commit message that COMMIT_EDITMSG would contain\n' \
    > "${TMPDIR_TEST}/.git/COMMIT_EDITMSG"
  _run_review || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  grep -q "DEVELOPER INTENT (commit message):" "${PROMPT_CAPTURE}"
  grep -q "previous commit message that COMMIT_EDITMSG would contain" "${PROMPT_CAPTURE}"
}

@test "--message-file=PATH strips git-template '#'-prefixed comment lines" {
  cat > "${MOCK_DIR}/msg-with-comments.txt" <<'EOF'
feat: real message line one

This is the body of the commit.

# Please enter the commit message for your changes. Lines starting
# with '#' will be ignored, and an empty message aborts the commit.
#
# On branch test-branch
# Changes to be committed:
#       new file:   foo.txt
EOF
  _run_review --message-file="${MOCK_DIR}/msg-with-comments.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  grep -q "feat: real message line one" "${PROMPT_CAPTURE}"
  grep -q "This is the body of the commit." "${PROMPT_CAPTURE}"
  # Comment lines must NOT leak into the prompt.
  ! grep -q "Please enter the commit message" "${PROMPT_CAPTURE}"
  ! grep -q "On branch test-branch" "${PROMPT_CAPTURE}"
  ! grep -q "new file:   foo.txt" "${PROMPT_CAPTURE}"
}

@test "--message-file overrides COMMIT_EDITMSG when both are present" {
  # Verifies the priority order documented in _read_commit_message: the
  # flag wins over the per-mode default source. This is the production
  # case once the commit-msg hook starts passing --message-file="$1".
  printf 'STALE message from COMMIT_EDITMSG\n' \
    > "${TMPDIR_TEST}/.git/COMMIT_EDITMSG"
  echo "FRESH message from --message-file" > "${MOCK_DIR}/msg.txt"
  _run_review --message-file="${MOCK_DIR}/msg.txt" || true
  [[ -f "${PROMPT_CAPTURE}" ]]
  grep -q "FRESH message from --message-file" "${PROMPT_CAPTURE}"
  ! grep -q "STALE message from COMMIT_EDITMSG" "${PROMPT_CAPTURE}"
}
