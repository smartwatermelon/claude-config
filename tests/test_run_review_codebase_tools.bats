#!/usr/bin/env bats
# Tests for the tool flags hooks/run-review.sh passes in --mode=codebase.
#
# claude-config#681: codebase mode passed --allowedTools "Read,Grep,Glob"
# alone. A probe during #680 showed that this still loads every configured
# MCP server (Gmail, Drive, Notion, 1Password) into the reviewer. The chunked
# arbiter passes --tools, --allowedTools and --strict-mcp-config; codebase
# mode must pass the same three.
#
# Run: bats tests/test_run_review_codebase_tools.bats

# Resolve the script under test relative to THIS test file, not via
# ${HOME}/.claude/hooks, so a worktree tests its own copy.
SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

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

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  # Fake HOME so the run cannot read or write the real ~/.claude.
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude"

  # Mock claude CLI. Every --agent call appends its argv to ${ARGV_RECORD} as
  # one line, each argument in brackets, so [--tools][] is distinguishable
  # from [--tools][Read,Grep,Glob]. It always answers PASS.
  export ARGV_RECORD="${MOCK_DIR}/argv-invoked"
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
argv_line=""
is_agent=false
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "\$a" == "--agent" ]] && is_agent=true
  argv_line="\${argv_line}[\$a]"
done
cat >/dev/null
[[ "\${is_agent}" == true ]] && printf '%s\n' "\${argv_line}" >>"${ARGV_RECORD}"
jq -n '{type:"result",subtype:"success",is_error:false,
        result:"VERDICT: PASS\nNo blocking issues found.",
        structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

_run_codebase_review() {
  local diff
  printf 'echo "hello"\n' >"${TMPDIR_TEST}/a.sh"
  git -C "${TMPDIR_TEST}" add a.sh
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" --mode=codebase --no-file
  )
}

@test "#681: codebase mode passes --tools, --allowedTools and --strict-mcp-config" {
  run _run_codebase_review
  [ "$status" -eq 0 ]
  grep -q '^codebase: PASS' "${EXPECTED_LOG}"
  # Exactly one reviewer call: the codebase adversarial-reviewer.
  [ "$(grep -c . "${ARGV_RECORD}")" -eq 1 ]
  local argv
  argv=$(cat "${ARGV_RECORD}")
  [[ "${argv}" == *"[--agent][adversarial-reviewer]"* ]]
  [[ "${argv}" == *"[--tools][Read,Grep,Glob]"* ]]
  [[ "${argv}" == *"[--allowedTools][Read,Grep,Glob]"* ]]
  [[ "${argv}" == *"[--strict-mcp-config]"* ]]
  [[ "${argv}" != *"[--tools][]"* ]]
}
