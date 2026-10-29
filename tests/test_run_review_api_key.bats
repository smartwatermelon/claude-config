#!/usr/bin/env bats
# Tests for run_claude_cli in hooks/run-review.sh: the reviewer API key.
#
# A Max plan's monthly API credit reaches `claude -p` only when it runs on the
# linked Console org's API key. run-review.sh reads that key from the login
# Keychain and sets ANTHROPIC_API_KEY in the reviewer's child env only. These
# tests pin the contract:
#   - no key (the work Mac, any fresh machine): one plain run, no key in the
#     child env, nothing printed about it;
#   - key: the child sees it in its environment, never in any argv;
#   - a keyed run that fails (non-zero, or exit 0 with is_error) is retried
#     exactly once on the subscription, with identical stdin and no key;
#   - a keyed run that times out (124) is not retried, and 124 surfaces;
#   - REVIEW_API_KEY_DISABLE=1 never touches the Keychain;
#   - every run appends one line to the usage ledger;
#   - every run, retries included, starts with no MCP servers and no
#     telemetry or error reporting.
#
# `security` and `claude` are both mocks. No real keychain is read.
#
# Run: bats tests/test_run_review_api_key.bats

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/run-review.sh"
FAKE_KEY="sk-ant-api03-TESTKEY_abc-123"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  printf '#!/usr/bin/env bash\n' >"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export LEDGER="${MOCK_DIR}/ledger.jsonl"
  export FAKE_KEY

  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # Mock `security`: prints FAKE_KEY for `find-generic-password ... -w` when
  # ${MOCK_DIR}/has-key exists, else exits 44 ("item not found") silently on
  # stdout. Every call is logged so the opt-out can prove it made none.
  cat >"${MOCK_DIR}/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_DIR}/security-calls"
[[ "$1" == "find-generic-password" ]] || exit 1
if [[ -f "${MOCK_DIR}/has-key" ]]; then
  printf '%s\n' "${FAKE_KEY}"
  exit 0
fi
echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
exit 44
EOF
  chmod +x "${MOCK_DIR}/security"

  # Mock claude. Records, per agent and per call N: the ANTHROPIC_API_KEY it
  # saw (env-<agent>-N), its argv, its parent's argv (the `timeout` process,
  # since `env` execs into this script), and its stdin. Behavior when it has
  # a key is switched by ${MOCK_DIR}/keyed-{fail,timeout,iserror0}. The
  # haiku-alias probe has no --agent and is recorded as "probe".
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
agent=""
prev=""
for a in "$@"; do
  if [[ "$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "$prev" == "--agent" ]] && agent="$a"
  prev="$a"
done
[[ "${agent}" == *code-reviewer ]] && agent=code-reviewer
[[ -n "${agent}" ]] || agent=probe
n=$(($(cat "${MOCK_DIR}/count-${agent}" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${MOCK_DIR}/count-${agent}"
printf '%s\n' "${ANTHROPIC_API_KEY:-<unset>}" >"${MOCK_DIR}/env-${agent}-${n}"
printf 'DISABLE_TELEMETRY=%s DISABLE_ERROR_REPORTING=%s\n' \
  "${DISABLE_TELEMETRY:-<unset>}" "${DISABLE_ERROR_REPORTING:-<unset>}" >"${MOCK_DIR}/quiet-${agent}-${n}"
printf '%s\n' "$*" >"${MOCK_DIR}/argv-${agent}-${n}"
ps -o args= -p "${PPID}" >"${MOCK_DIR}/parent-${agent}-${n}" 2>/dev/null || true
cat >"${MOCK_DIR}/stdin-${agent}-${n}"
err_json='{"type":"result","subtype":"success","is_error":true,"api_error_status":401,"total_cost_usd":0,"result":"Invalid API key · Fix external API key"}'
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set and takes precedence over your claude.ai login · Unset it to load your organization's connectors" >&2
  [[ -f "${MOCK_DIR}/keyed-timeout" ]] && exit 124
  if [[ -f "${MOCK_DIR}/keyed-nocredit" ]]; then
    printf '%s\n' '{"type":"result","subtype":"success","is_error":true,"total_cost_usd":0,"result":"Credit balance is too low to access the Anthropic API"}'
    exit 1
  fi
  if [[ -f "${MOCK_DIR}/keyed-fail" ]]; then
    printf '%s\n' "${err_json}"
    exit 1
  fi
  if [[ -f "${MOCK_DIR}/keyed-iserror0" ]]; then
    printf '%s\n' "${err_json}"
    exit 0
  fi
fi
jq -n '{type:"result",subtype:"success",is_error:false,total_cost_usd:0.05,
        result:"VERDICT: PASS\nNo blocking issues found.",
        structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  printf 'echo hello\n' >>"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Extra VAR=value words in $@ go to the script's environment.
_run_review() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | env -u ANTHROPIC_API_KEY -u REVIEW_API_KEY_DISABLE \
        HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        REVIEW_SECURITY_BIN="${MOCK_DIR}/security" REVIEW_API_USAGE_LOG="${LEDGER}" \
        GIT_CONFIG_GLOBAL=/dev/null "$@" bash "${SCRIPT}"
  )
}

# How many times the mock ran as agent $1 equals $2.
_count_is() {
  local n=0
  [[ ! -f "${MOCK_DIR}/count-$1" ]] || n=$(<"${MOCK_DIR}/count-$1")
  [[ "${n}" -eq "$2" ]]
}

# The ANTHROPIC_API_KEY the mock saw on call $1 (agent-N) equals $2.
_env_is() {
  local v
  v=$(<"${MOCK_DIR}/env-$1") || return 1
  [[ "${v}" == "$2" ]]
}

# _ledger_n <test-op> <n> [jq args...] <filter>: the filter's number over
# the slurped ledger compares to n.
_ledger_n() {
  local op="$1" want="$2" got
  shift 2
  got=$(jq -s "$@" "${LEDGER}") || return 1
  case "${op}" in
    -eq) ((got == want)) ;;
    -ge) ((got >= want)) ;;
    *) return 1 ;;
  esac
}

@test "no key: one run per agent, no ANTHROPIC_API_KEY in the child, no noise" {
  run _run_review
  [ "$status" -eq 0 ]
  _count_is code-reviewer 1
  _count_is adversarial-reviewer 1
  _env_is code-reviewer-1 "<unset>"
  _env_is adversarial-reviewer-1 "<unset>"
  [[ "$output" != *"API-key run"* ]]
  [[ "$output" != *"could not be found"* ]]
  # The Keychain was asked, and its "not found" was silent.
  [ -s "${MOCK_DIR}/security-calls" ]
}

@test "key present: the child sees it in its env, never in argv" {
  touch "${MOCK_DIR}/has-key"
  run _run_review
  [ "$status" -eq 0 ]
  _count_is code-reviewer 1
  _count_is adversarial-reviewer 1
  _env_is code-reviewer-1 "${FAKE_KEY}"
  _env_is adversarial-reviewer-1 "${FAKE_KEY}"
  # The haiku-alias probe goes through the same helper.
  _env_is probe-1 "${FAKE_KEY}"
  ! grep -qF "${FAKE_KEY}" "${MOCK_DIR}"/argv-* || false
  # The parent is `timeout`; its argv must not carry the key either.
  [ -s "${MOCK_DIR}/parent-code-reviewer-1" ]
  ! grep -qF "${FAKE_KEY}" "${MOCK_DIR}"/parent-* || false
  # Never printed, and the connector notice is filtered.
  [[ "$output" != *"${FAKE_KEY}"* ]]
  [[ "$output" != *"connectors are disabled"* ]]
}

@test "keyed failure: exactly one retry on the subscription, same stdin, no key" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-fail"
  # An inherited key must not sneak into the retry.
  run _run_review ANTHROPIC_API_KEY=sk-ant-api03-inherited
  [ "$status" -eq 0 ]
  _count_is code-reviewer 2
  _count_is adversarial-reviewer 2
  _env_is code-reviewer-1 "${FAKE_KEY}"
  _env_is code-reviewer-2 "<unset>"
  _env_is adversarial-reviewer-2 "<unset>"
  [ -s "${MOCK_DIR}/stdin-code-reviewer-1" ]
  cmp -s "${MOCK_DIR}/stdin-code-reviewer-1" "${MOCK_DIR}/stdin-code-reviewer-2"
  cmp -s "${MOCK_DIR}/stdin-adversarial-reviewer-1" "${MOCK_DIR}/stdin-adversarial-reviewer-2"
  [[ "$output" == *"API-key run failed (exit 1): Invalid API key"*"retrying on subscription"* ]]
  [[ "$output" != *"${FAKE_KEY}"* ]]
  grep -qx 'code-reviewer: PASS' "${EXPECTED_LOG}"
}

@test "keyed failure from exhausted credit: calm refill note, still one retry" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-nocredit"
  run _run_review
  [ "$status" -eq 0 ]
  _count_is code-reviewer 2
  _env_is code-reviewer-2 "<unset>"
  [[ "$output" == *"credit is used up for this month (it refills on the 1st); using the subscription. No action needed."* ]]
  [[ "$output" != *"API-key run failed"* ]]
  grep -qx 'code-reviewer: PASS' "${EXPECTED_LOG}"
}

@test "keyed exit 0 with is_error: treated as a failure and retried once" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-iserror0"
  run _run_review
  [ "$status" -eq 0 ]
  _count_is code-reviewer 2
  _env_is code-reviewer-2 "<unset>"
  [[ "$output" == *"API-key run failed (exit 0): Invalid API key"* ]]
  grep -qx 'code-reviewer: PASS' "${EXPECTED_LOG}"
}

@test "keyed timeout: no retry, 124 surfaces as a timeout" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-timeout"
  run _run_review
  [ "$status" -eq 1 ]
  _count_is code-reviewer 1
  _count_is adversarial-reviewer 1
  [[ "$output" != *"retrying on subscription"* ]]
  grep -qx 'code-reviewer: INCOMPLETE (timeout)' "${EXPECTED_LOG}"
}

@test "REVIEW_API_KEY_DISABLE=1: the Keychain is never read, no key in the child" {
  touch "${MOCK_DIR}/has-key"
  run _run_review REVIEW_API_KEY_DISABLE=1
  [ "$status" -eq 0 ]
  [ ! -e "${MOCK_DIR}/security-calls" ]
  _env_is code-reviewer-1 "<unset>"
}

@test "a value that is not an API key is treated as no key" {
  cat >"${MOCK_DIR}/security" <<'EOF'
#!/usr/bin/env bash
echo "not a key"
EOF
  run _run_review
  [ "$status" -eq 0 ]
  _env_is code-reviewer-1 "<unset>"
}

# Every recorded call (agents, arbiter, haiku probe) had --strict-mcp-config
# in argv and telemetry and error reporting off in its env.
_all_calls_quiet() {
  local f n=0
  for f in "${MOCK_DIR}"/argv-*; do
    [[ -e "${f}" ]] || return 1
    n=$((n + 1))
    grep -qF -- "--strict-mcp-config" "${f}" || return 1
    grep -qx 'DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1' "${f/argv-/quiet-}" || return 1
  done
  ((n > 0))
}

@test "no key: every call runs without MCP servers or telemetry" {
  run _run_review
  [ "$status" -eq 0 ]
  _all_calls_quiet
}

@test "key and failed-key retry: every call runs without MCP servers or telemetry" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-fail"
  run _run_review
  [ "$status" -eq 0 ]
  # The probe and both reviewers ran keyed, then again on the subscription.
  _count_is code-reviewer 2
  [ -e "${MOCK_DIR}/argv-probe-1" ]
  _all_calls_quiet
}

@test "ledger: one JSON line per run, with auth, exit and cost" {
  touch "${MOCK_DIR}/has-key" "${MOCK_DIR}/keyed-fail"
  run _run_review
  [ "$status" -eq 0 ]
  repo=$(basename "${TMPDIR_TEST}")
  # Per reviewer: the failed keyed run, then the fallback.
  _ledger_n -ge 2 '[.[] | select(.auth == "api" and .exit == 1)] | length'
  _ledger_n -ge 2 '[.[] | select(.auth == "subscription-fallback" and .exit == 0 and .total_cost_usd == 0.05)] | length'
  REPO_EXPECT="${repo}" _ledger_n -eq 0 '[.[] | select(.repo != env.REPO_EXPECT)] | length'
  _ledger_n -eq 0 '[.[] | select(.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$") | not)] | length'
  ! grep -qF "${FAKE_KEY}" "${LEDGER}" || false
}

@test "ledger: no-key runs are logged as subscription" {
  run _run_review
  [ "$status" -eq 0 ]
  _ledger_n -ge 2 '[.[] | select(.auth == "subscription")] | length'
  _ledger_n -eq 0 '[.[] | select(.auth != "subscription")] | length'
}

@test "ledger: an unwritable ledger path does not fail the review" {
  touch "${MOCK_DIR}/has-key"
  printf 'x' >"${MOCK_DIR}/blocker"
  LEDGER="${MOCK_DIR}/blocker/sub/ledger.jsonl"
  run _run_review
  [ "$status" -eq 0 ]
  grep -qx 'code-reviewer: PASS' "${EXPECTED_LOG}"
}
