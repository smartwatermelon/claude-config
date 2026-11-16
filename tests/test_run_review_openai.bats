#!/usr/bin/env bats
# Tests for the advisory OpenAI review in hooks/run-review.sh (full-diff mode).
#
# The pre-push full-diff review also sends its prompt to the OpenAI Responses
# API, paid by a monthly credit grant. These tests pin the contract:
#   - it never changes the exit code: a passing adversarial review still exits
#     0 and a blocking one still exits 1, whatever OpenAI returns;
#   - each failure is one "skipped" notice: no key, curl missing, diff over
#     the byte cap, timeout, non-2xx HTTP, an .error body, an empty answer;
#   - HTTP 429 insufficient_quota prints the "credit used up" line;
#   - the key reaches curl on stdin only, never in argv;
#   - never retried: one curl call per run at most;
#   - commit mode and REVIEW_OPENAI_DISABLE=1 never read the OpenAI key;
#   - one ledger line per call, auth "openai-api", with token usage.
#
# `security`, `claude` and `curl` are mocks. No keychain or network is used.
#
# Run: bats tests/test_run_review_openai.bats

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/run-review.sh"
FAKE_OPENAI_KEY="sk-proj-TESTKEY_openai-123"

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
  printf 'echo hello\n' >>"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "branch change"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export LEDGER="${MOCK_DIR}/ledger.jsonl"
  export FAKE_OPENAI_KEY

  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents"
  touch "${FAKE_HOME}/.claude/plugins/marketplaces/test/agents/adversarial-reviewer.md"

  # security: has the OpenAI key (when has-openai-key exists), never the
  # Anthropic one, so the claude mock always runs on the subscription path.
  cat >"${MOCK_DIR}/security" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_DIR}/security-calls"
if [[ "$*" == *"-s openai-reviewer-api-key"* && -f "${MOCK_DIR}/has-openai-key" ]]; then
  printf '%s\n' "${FAKE_OPENAI_KEY}"
  exit 0
fi
exit 44
EOF

  # claude: PASS, or a BLOCKING FAIL on foo.sh when claude-block exists.
  cat >"${MOCK_DIR}/claude" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && { echo "mock-claude 0.0.1"; exit 0; }; done
cat >/dev/null
if [[ -f "${MOCK_DIR}/claude-block" ]]; then
  jq -n '{type:"result",subtype:"success",is_error:false,total_cost_usd:0.05,
          result:"VERDICT: FAIL",
          structured_output:{verdict:"FAIL",blocking:true,
            findings:[{severity:"BLOCKING",location:"foo.sh:2",issue:"broken echo",details:"d"}]}}'
  exit 0
fi
jq -n '{type:"result",subtype:"success",is_error:false,total_cost_usd:0.05,
        result:"VERDICT: PASS\nNo cross-file integration issues found.",
        structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF

  # curl: records argv and stdin (headers), copies the --data-binary body,
  # writes ${MOCK_DIR}/resp.json to the -o path, prints http-code. Exits with
  # curl-rc when that file exists (28 = curl's timeout).
  cat >"${MOCK_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "${MOCK_DIR}/curl-count" 2>/dev/null || echo 0) + 1))
echo "${n}" >"${MOCK_DIR}/curl-count"
printf '%s\n' "$*" >>"${MOCK_DIR}/curl-argv"
cat >>"${MOCK_DIR}/curl-stdin"
out=""
prev=""
for a in "$@"; do
  [[ "${prev}" == "-o" ]] && out="$a"
  [[ "${prev}" == "--data-binary" ]] && cp "${a#@}" "${MOCK_DIR}/body-seen.json"
  prev="$a"
done
if [[ -f "${MOCK_DIR}/curl-rc" ]]; then
  echo "curl: (28) Operation timed out" >&2
  exit "$(<"${MOCK_DIR}/curl-rc")"
fi
[[ -n "${out}" ]] && cp "${MOCK_DIR}/resp.json" "${out}"
cat "${MOCK_DIR}/http-code"
EOF
  chmod +x "${MOCK_DIR}/security" "${MOCK_DIR}/claude" "${MOCK_DIR}/curl"

  printf '200' >"${MOCK_DIR}/http-code"
  jq -n '{status:"completed",
          output:[{type:"reasoning",summary:[]},
                  {type:"message",content:[{type:"output_text",text:"OPENAI-SAYS: foo.sh looks fine"}]}],
          usage:{input_tokens:1234,output_tokens:567}}' >"${MOCK_DIR}/resp.json"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Extra VAR=value words in $@ go to the script's environment.
_run_full_diff() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff HEAD~1 HEAD)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | env -u REVIEW_OPENAI_DISABLE -u ANTHROPIC_API_KEY \
        HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${MOCK_DIR}/claude" \
        REVIEW_SECURITY_BIN="${MOCK_DIR}/security" REVIEW_API_USAGE_LOG="${LEDGER}" \
        REVIEW_OPENAI_CURL_BIN="${MOCK_DIR}/curl" REVIEW_OPENAI_API_BASE="http://mock.invalid" \
        GIT_CONFIG_GLOBAL=/dev/null "$@" bash "${SCRIPT}" --mode=full-diff
  )
}

_curl_calls() {
  local n=0
  [[ ! -f "${MOCK_DIR}/curl-count" ]] || n=$(<"${MOCK_DIR}/curl-count")
  echo "${n}"
}

@test "success + adversarial PASS: review shown, exit 0, key only on stdin" {
  touch "${MOCK_DIR}/has-openai-key"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"=== OPENAI REVIEW (advisory, non-blocking; gpt-5.5) ==="* ]]
  [[ "$output" == *"OPENAI-SAYS: foo.sh looks fine"* ]]
  grep -qF "OPENAI-SAYS" "${EXPECTED_LOG}"
  [ "$(_curl_calls)" -eq 1 ]
  # The key: on stdin as a Bearer header, never in argv, never printed.
  grep -qxF "Authorization: Bearer ${FAKE_OPENAI_KEY}" "${MOCK_DIR}/curl-stdin"
  ! grep -qF "${FAKE_OPENAI_KEY}" "${MOCK_DIR}/curl-argv" || false
  [[ "$output" != *"${FAKE_OPENAI_KEY}"* ]]
  # The body carries the full-diff prompt, the model and the output cap.
  jq -e '.model == "gpt-5.5" and .max_output_tokens == 16000 and .store == false
         and (.input | contains("pre-push full-diff review")) and (.input | contains("echo hello"))' \
    "${MOCK_DIR}/body-seen.json"
  [[ "$(<"${MOCK_DIR}/curl-argv")" == *"http://mock.invalid/v1/responses"* ]]
}

@test "success + adversarial BLOCKING: still exit 1, OpenAI text shown" {
  touch "${MOCK_DIR}/has-openai-key" "${MOCK_DIR}/claude-block"
  run _run_full_diff
  [ "$status" -eq 1 ]
  [[ "$output" == *"OPENAI-SAYS: foo.sh looks fine"* ]]
  [[ "$output" == *"Full-diff review found blocking cross-file issues"* ]]
}

@test "OpenAI error + adversarial BLOCKING: still exit 1" {
  touch "${MOCK_DIR}/has-openai-key" "${MOCK_DIR}/claude-block"
  printf '500' >"${MOCK_DIR}/http-code"
  jq -n '{error:{message:"server exploded",code:null}}' >"${MOCK_DIR}/resp.json"
  run _run_full_diff
  [ "$status" -eq 1 ]
  [[ "$output" == *"OpenAI review skipped: HTTP 500: server exploded"* ]]
}

@test "no key: one skip notice, curl never called, exit 0" {
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: no key in Keychain service openai-reviewer-api-key"* ]]
  [ "$(_curl_calls)" -eq 0 ]
}

@test "curl missing: one skip notice, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  run _run_full_diff REVIEW_OPENAI_CURL_BIN="${MOCK_DIR}/no-such-curl"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: ${MOCK_DIR}/no-such-curl not found"* ]]
}

@test "diff over the byte cap: skipped before any call, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  git -C "${TMPDIR_TEST}" config review.openaiMaxDiffBytes 10
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"over review.openaiMaxDiffBytes (10)"* ]]
  [ "$(_curl_calls)" -eq 0 ]
}

@test "timeout (curl exit 28): one notice, no retry, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  printf '28' >"${MOCK_DIR}/curl-rc"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: no answer within 300s"* ]]
  [ "$(_curl_calls)" -eq 1 ]
}

@test "credit used up (429 insufficient_quota): the calm line, no retry, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  printf '429' >"${MOCK_DIR}/http-code"
  jq -n '{error:{message:"You exceeded your current quota",type:"insufficient_quota",code:"insufficient_quota"}}' \
    >"${MOCK_DIR}/resp.json"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI credit used up for this month; skipped"* ]]
  [ "$(_curl_calls)" -eq 1 ]
}

@test "other HTTP error: status and the first 300 chars of the message" {
  touch "${MOCK_DIR}/has-openai-key"
  printf '400' >"${MOCK_DIR}/http-code"
  long=$(printf 'x%.0s' {1..500})
  jq -n --arg m "bad request ${long}" '{error:{message:$m,code:"invalid_request_error"}}' >"${MOCK_DIR}/resp.json"
  run _run_full_diff
  [ "$status" -eq 0 ]
  line=$(printf '%s\n' "$output" | grep 'OpenAI review skipped: HTTP 400: bad request')
  [ "${#line}" -lt 380 ]
}

@test "2xx with .error set: skipped, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  jq -n '{error:{message:"odd but possible",code:"x"}}' >"${MOCK_DIR}/resp.json"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: HTTP 200: odd but possible"* ]]
  [[ "$output" != *"OPENAI REVIEW"* ]]
}

@test "empty answer (incomplete, reasoning only): skipped, exit 0" {
  touch "${MOCK_DIR}/has-openai-key"
  jq -n '{status:"incomplete",output:[{type:"reasoning",summary:[]}],usage:{input_tokens:1,output_tokens:16000}}' \
    >"${MOCK_DIR}/resp.json"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: the response had no text (status incomplete)"* ]]
}

@test "REVIEW_OPENAI_DISABLE=1: the OpenAI key is never read, no call" {
  touch "${MOCK_DIR}/has-openai-key"
  run _run_full_diff REVIEW_OPENAI_DISABLE=1
  [ "$status" -eq 0 ]
  ! grep -q 'openai-reviewer-api-key' "${MOCK_DIR}/security-calls" || false
  [ "$(_curl_calls)" -eq 0 ]
}

@test "cached PASS: skipped with a notice, no call" {
  touch "${MOCK_DIR}/has-openai-key"
  run _run_full_diff
  [ "$status" -eq 0 ]
  [ "$(_curl_calls)" -eq 1 ]
  run _run_full_diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenAI review skipped: cached PASS"* ]]
  [ "$(_curl_calls)" -eq 1 ]
}

@test "commit mode never reads the OpenAI key" {
  touch "${MOCK_DIR}/has-openai-key"
  printf 'echo again\n' >>"${TMPDIR_TEST}/foo.sh"
  git -C "${TMPDIR_TEST}" add foo.sh
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  run bash -c 'cd "$1" && printf "%s\n" "$2" | HOME="$3" REVIEW_LOG="$4" CLAUDE_CLI="$5" \
    REVIEW_SECURITY_BIN="$6" REVIEW_API_USAGE_LOG="$7" REVIEW_OPENAI_CURL_BIN="$8" \
    GIT_CONFIG_GLOBAL=/dev/null bash "$9"' _ \
    "${TMPDIR_TEST}" "${diff}" "${FAKE_HOME}" "${EXPECTED_LOG}" "${MOCK_DIR}/claude" \
    "${MOCK_DIR}/security" "${LEDGER}" "${MOCK_DIR}/curl" "${SCRIPT}"
  ! grep -q 'openai-reviewer-api-key' "${MOCK_DIR}/security-calls" || false
  [ "$(_curl_calls)" -eq 0 ]
}

@test "ledger: one openai-api line with token usage" {
  touch "${MOCK_DIR}/has-openai-key"
  run _run_full_diff
  [ "$status" -eq 0 ]
  jq -se '[.[] | select(.auth == "openai-api")] | length == 1
          and .[0].input_tokens == 1234 and .[0].output_tokens == 567
          and .[0].http == 200 and .[0].model == "gpt-5.5"' "${LEDGER}"
}
