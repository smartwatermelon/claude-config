#!/usr/bin/env bats
# review.arbiterTimeout (#682): the arbiter no longer shares review.timeout (both paths since claude-config#799).
# Setup mirrors test_run_review_chunked.bats.

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
CODE_REVIEWER="comprehensive-review:comprehensive-review-code-reviewer"

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

  # Three 20-line files land in the chunked band.
  git -C "${TMPDIR_TEST}" config review.maxLines 50
  git -C "${TMPDIR_TEST}" config review.chunkSize 30

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # Mock CLI: code-reviewer blocks on a.sh:1, adversarial passes, the arbiter
  # (--allowedTools) sleeps arbiter-sleep seconds, then PASS.
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
agent=""
prev=""
is_arbiter=false
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "\$prev" == "--agent" ]] && agent="\$a"
  [[ "\$a" == "--allowedTools" ]] && is_arbiter=true
  prev="\$a"
done
cat >/dev/null
if [[ "\${is_arbiter}" == true ]]; then
  if [[ -s "${MOCK_DIR}/arbiter-sleep" ]]; then
    sleep "\$(cat "${MOCK_DIR}/arbiter-sleep")"
  fi
  # An ARBITER_JSON_SCHEMA REFUTED with proof, which clears (claude-config#799).
  jq -n '{type:"result",subtype:"success",is_error:false,
    result:"{}",
    structured_output:{ruling:"REFUTED",reason:"Read a.sh; the claim does not match the code.",
      refutation:{location:"a.sh:1-2",quoted_code:"echo \\"line 0\\"\necho \\"line 1\\"",reason:"mock"}}}'
  exit 0
fi
if [[ "\${agent}" == "${CODE_REVIEWER}" ]]; then
  jq -n '{type:"result",subtype:"success",is_error:false,
    result:"VERDICT: FAIL\nISSUE: arguments reversed\nSEVERITY: BLOCKING\nLOCATION: a.sh:1\nDETAILS: mock",
    structured_output:{verdict:"FAIL",blocking:true,
      findings:[{severity:"BLOCKING",location:"a.sh:1",issue:"arguments reversed"}]}}'
  exit 0
fi
jq -n '{type:"result",subtype:"success",is_error:false,
  result:"VERDICT: PASS\nNo blocking issues found.",
  structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  local f i
  for f in a.sh b.sh c.sh; do
    : >"${TMPDIR_TEST}/${f}"
    for ((i = 0; i < 20; i += 1)); do
      printf 'echo "line %d"\n' "${i}" >>"${TMPDIR_TEST}/${f}"
    done
  done
  git -C "${TMPDIR_TEST}" add a.sh b.sh c.sh
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Run inside the temp repo, with global review.* keys kept out.
_run_review() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" "$@"
  )
}

@test "#682: an arbiter slower than review.timeout but within review.arbiterTimeout clears the block" {
  git -C "${TMPDIR_TEST}" config review.timeout 2
  git -C "${TMPDIR_TEST}" config review.arbiterTimeout 15
  echo 4 >"${MOCK_DIR}/arbiter-sleep"

  run _run_review
  [ "$status" -eq 0 ]
  grep -q '^arbiter: PASS (a.sh)' "${EXPECTED_LOG}"
  [[ "$output" == *"Cleared by arbiter: 1/1"* ]]
}

@test "#682: an arbiter timeout still blocks and is logged apart from a real FAIL" {
  git -C "${TMPDIR_TEST}" config review.arbiterTimeout 2
  echo 6 >"${MOCK_DIR}/arbiter-sleep"

  run _run_review
  [ "$status" -ne 0 ]
  # Still the fail-closed verdict line, with the timeout named on it.
  grep -q '^arbiter: FAIL (a.sh) - timed out after 2s, no ruling' "${EXPECTED_LOG}"
  [[ "$output" == *"review.arbiterTimeout"* ]]
  [[ "$output" != *"Cleared by arbiter"* ]]
}

@test "#682: an arbiter that answers in time carries no timeout marker" {
  git -C "${TMPDIR_TEST}" config review.arbiterTimeout 15

  run _run_review
  [ "$status" -eq 0 ]
  ! grep -q 'timed out' "${EXPECTED_LOG}" || false
}

# 600s since claude-config#799: both arbiters run Opus with tools and must quote proof.
@test "#682/#799: review.arbiterTimeout defaults to 600s" {
  # The slow notice prints the timeout in force for the call.
  git -C "${TMPDIR_TEST}" config review.slowNotice 1
  echo 2 >"${MOCK_DIR}/arbiter-sleep"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" == *"adversarial-reviewer has not responded after 1s — still waiting (timeout at 600s)"* ]]
}

@test "#682: with review.arbiterTimeout unset, the arbiter never gets less than review.timeout" {
  git -C "${TMPDIR_TEST}" config review.timeout 900
  git -C "${TMPDIR_TEST}" config review.slowNotice 1
  echo 2 >"${MOCK_DIR}/arbiter-sleep"

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" == *"adversarial-reviewer has not responded after 1s — still waiting (timeout at 900s)"* ]]
}
