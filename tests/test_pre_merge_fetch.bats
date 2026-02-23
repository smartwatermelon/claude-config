#!/usr/bin/env bats
# Tests for _fetch_pr_json in ~/.claude/hooks/pre-merge-review.sh
#
# Verifies that gh stderr output (debug lines, upgrade notices, warnings)
# does not contaminate the JSON capture, which causes jq parse failures.
#
# Bug: _fetch_pr_json used `2>&1` when capturing gh output, merging gh's
# stderr into the JSON string. Any gh stderr output causes jq to fail with:
#   jq: parse error: Invalid numeric literal at line 1, column 5
#
# Run: bats ~/.claude/tests/test_pre_merge_fetch.bats

SCRIPT="${HOME}/.claude/hooks/pre-merge-review.sh"
VALID_JSON='{"number":53,"title":"test PR","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Load _fetch_pr_json and its required dependencies into the current shell.
# Extracts the function definition from the script without executing the body.
_load_fetch_fn() {
  # export so the eval'd function body can reference them
  export PR_JSON_FIELDS="number,title,state,reviews,comments,reviewDecision,statusCheckRollup"
  export PR_JSON_FIELDS_FALLBACK="number,title,state,reviews,comments,reviewDecision"
  log_warn() { echo "WARN: $*" >&2; }
  log_error() { echo "ERROR: $*" >&2; }
  local func_def
  func_def=$(sed -n '/^_fetch_pr_json()/,/^}$/p' "${SCRIPT}")
  eval "${func_def}"
}

@test "_fetch_pr_json returns clean JSON when gh emits GH_DEBUG lines to stderr" {
  # Reproduces the GH_DEBUG=1 failure mode: gh emits bracketed debug lines
  # to stderr before the JSON. With 2>&1 these contaminate the result and
  # cause jq to fail: "Invalid numeric literal at line 1, column 5"
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf '[git remote -v]\n[git config --get-regexp ^remote]\n' >&2
printf '{"number":53,"title":"test PR","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}\n'
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  _load_fetch_fn
  result=$(_fetch_pr_json "53")

  pr_number=$(echo "${result}" | jq -r '.number')
  [[ "${pr_number}" = "53" ]]
}

@test "_fetch_pr_json returns clean JSON when gh emits upgrade notice to stderr" {
  # Reproduces the silent failure mode: gh emits upgrade notices to stderr
  # in normal operation. These also contaminate result via 2>&1.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'A new release of gh is available: 2.43.0 -> 2.44.0\nhttps://github.com/cli/cli/releases/tag/v2.44.0\n' >&2
printf '{"number":53,"title":"test PR","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[]}\n'
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  _load_fetch_fn
  result=$(_fetch_pr_json "53")

  pr_title=$(echo "${result}" | jq -r '.title')
  [[ "${pr_title}" = "test PR" ]]
}

@test "_fetch_pr_json retries with fallback fields on PAT permission error" {
  # Verifies the PAT retry path still works after the stderr fix.
  # First call: fails with PAT error in stderr (exit 1)
  # Second call: succeeds with fallback fields (no statusCheckRollup)
  local count_file="${MOCK_DIR}/call_count"
  local valid_json="${VALID_JSON}"

  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
count=\$(cat "${count_file}" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\${count}" >"${count_file}"
if [ "\${count}" -eq 1 ]; then
  printf 'statusCheckRollup not accessible by personal access token\n' >&2
  exit 1
fi
printf '%s\n' '${valid_json}'
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  _load_fetch_fn
  result=$(_fetch_pr_json "53")

  pr_number=$(echo "${result}" | jq -r '.number')
  [[ "${pr_number}" = "53" ]]
}

@test "_fetch_pr_json returns error when gh fails with non-PAT error" {
  # Verifies that genuine gh failures (auth error, network, etc.) still
  # cause the function to return 1 with an error message.
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'error connecting to api.github.com\n' >&2
exit 1
EOF
  chmod +x "${MOCK_DIR}/gh"

  _load_fetch_fn
  run _fetch_pr_json "53"

  [[ "${status}" -eq 1 ]]
}
