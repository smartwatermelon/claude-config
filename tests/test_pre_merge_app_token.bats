#!/usr/bin/env bats
# Tests the GitHub App token path in pre-merge-review.sh and
# hooks/lib-app-token.sh (smartwatermelon/claude-config#687).
#
# On a private repo the default gh credentials (fine-grained PATs) cannot read
# the status-check rollup. The hook then mints an App installation token and
# reads the rollup with it through the REAL gh binary. Every external command
# is mocked: op (1Password), curl (the App JWT calls), and the real gh. The
# private key is a throwaway made in setup(); openssl is the real one, so the
# JWT the hook builds is verified against the matching public key by the mock
# curl. No test reaches 1Password or GitHub.
#
# Run: bats tests/test_pre_merge_app_token.bats

bats_require_minimum_version 1.5.0

SCRIPT="${BATS_TEST_DIRNAME:-}/../hooks/pre-merge-review.sh"

FORBIDDEN_STDERR='GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup)'
PR_BASE='"number":31,"title":"ci read","reviewDecision":"","reviews":[],"comments":[],"state":"OPEN","baseRefName":"main","url":"https://github.com/o/r/pull/31","author":{"login":"someone"}'
MOCK_TOKEN='ghs_MOCKTOKENd41d8cd98f00b204e9800998ecf8427e'
MOCK_CLIENT_ID='Iv23liMOCKCLIENT'
REQ_ONE='{"contexts":["claude-review / run-review"]}'
HEAD_SHA='0123456789abcdef0123456789abcdef01234567'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  mkdir -p "${MOCK_DIR}/home/.claude/hooks" "${MOCK_DIR}/bin"
  # The policy says lock and check passes, so the run reaches the code under test.
  cat >"${MOCK_DIR}/home/.claude/hooks/merge-lock.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "policy" ]] && printf 'lock\trule 1\t*\n'
exit 0
EOF
  chmod +x "${MOCK_DIR}/home/.claude/hooks/merge-lock.sh"

  openssl genrsa -out "${MOCK_DIR}/key.pem" 2048 2>/dev/null
  openssl rsa -in "${MOCK_DIR}/key.pem" -pubout -out "${MOCK_DIR}/pub.pem" 2>/dev/null

  printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-x\n+y\n' >"${MOCK_DIR}/pr.diff"

  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
cat >"${MOCK_DIR}/prompt.txt"
echo "VERDICT: SAFE_TO_MERGE"
EOF
  chmod +x "${MOCK_DIR}/claude"

  # Default (PATH) gh: the PAT path. The rollup read fails FORBIDDEN unless
  # rollup_readable exists.
  printf '%s\n' "${FORBIDDEN_STDERR}" >"${MOCK_DIR}/forbidden.err"
  printf '{%s}\n' "${PR_BASE}" >"${MOCK_DIR}/pr.json"
  printf '%s\n' "${REQ_ONE}" >"${MOCK_DIR}/protection.json"
  cat >"${MOCK_DIR}/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    [[ "\$*" == *"--comments"* ]] && exit 0
    if [[ "\$*" == *statusCheckRollup* ]]; then
      if [[ -f "${MOCK_DIR}/rollup_readable" ]]; then
        jq -c '. + {statusCheckRollup: [{"__typename":"CheckRun","name":"claude-review / run-review","status":"COMPLETED","conclusion":"SUCCESS"}]}' "${MOCK_DIR}/pr.json"
        exit 0
      fi
      cat "${MOCK_DIR}/forbidden.err" >&2
      exit 1
    fi
    cat "${MOCK_DIR}/pr.json"; exit 0 ;;
  "pr diff") cat "${MOCK_DIR}/pr.diff"; exit 0 ;;
  "repo view") echo "o/r"; exit 0 ;;
esac
if [[ "\$1" == "api" && "\$2" == *"/protection/required_status_checks" ]]; then
  cat "${MOCK_DIR}/protection.json"; exit 0
fi
echo "[]"
EOF
  chmod +x "${MOCK_DIR}/bin/gh"

  # The real gh: answers the three REST reads only for the minted token.
  # The mock answers the pulls read (and its --jq) with a fixed SHA.
  printf '%s\n' '{"total_count":1,"check_runs":[{"name":"claude-review / run-review","status":"completed","conclusion":"success"}]}' \
    >"${MOCK_DIR}/check-runs.json"
  printf '%s\n' '{"state":"pending","total_count":0,"statuses":[]}' >"${MOCK_DIR}/status.json"
  cat >"${MOCK_DIR}/real-gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${MOCK_DIR}/real-gh.calls"
if [[ "\${GH_TOKEN:-}" != "${MOCK_TOKEN}" ]]; then
  echo "gh: Bad credentials (HTTP 401)" >&2; exit 1
fi
case "\$2" in
  repos/o/r/pulls/31) echo "${HEAD_SHA}" ;;
  repos/o/r/commits/${HEAD_SHA}/check-runs*)
    [[ -f "${MOCK_DIR}/check-runs.403" ]] && { echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }
    cat "${MOCK_DIR}/check-runs.json" ;;
  repos/o/r/commits/${HEAD_SHA}/status*) cat "${MOCK_DIR}/status.json" ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
EOF
  chmod +x "${MOCK_DIR}/real-gh"

  # op: client ID and key. op.mode selects a failure.
  echo ok >"${MOCK_DIR}/op.mode"
  cat >"${MOCK_DIR}/op" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${MOCK_DIR}/op.calls"
mode=\$(cat "${MOCK_DIR}/op.mode")
[[ "\${mode}" == "fail" ]] && { echo "[ERROR] not signed in" >&2; exit 1; }
case "\$2" in
  */client_id) echo "${MOCK_CLIENT_ID}" ;;
  */*.pem)
    if [[ "\${mode}" == "badkey" ]]; then echo "-----BEGIN RSA PRIVATE KEY----- flattened -----END RSA PRIVATE KEY-----"
    else cat "${MOCK_DIR}/key.pem"; fi ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${MOCK_DIR}/op"

  # curl: verifies the Bearer JWT (signature, iss, lifetime) and serves the
  # two App endpoints. Never records the JWT itself.
  printf '%s\n' '[{"id":777,"account":{"login":"o"}}]' >"${MOCK_DIR}/installations.json"
  cat >"${MOCK_DIR}/curl" <<EOF
#!/usr/bin/env bash
cfg="" url="" method=GET data=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --config) cfg="\$2"; shift 2 ;;
    -X) method="\$2"; shift 2 ;;
    --data) data="\$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
jwt=\$(sed -n 's/^header = "Authorization: Bearer \(.*\)"\$/\1/p' "\${cfg}")
IFS=. read -r h p s <<<"\${jwt}"
b64d() { local x="\${1//-/+}"; x="\${x//_//}"; while (( \${#x} % 4 )); do x="\${x}="; done; printf '%s' "\${x}" | openssl base64 -d -A; }
b64d "\${s}" >"${MOCK_DIR}/sig.bin"
if ! printf '%s.%s' "\${h}" "\${p}" | openssl dgst -sha256 -verify "${MOCK_DIR}/pub.pem" -signature "${MOCK_DIR}/sig.bin" >/dev/null 2>&1; then
  echo "jwt_bad_signature" >>"${MOCK_DIR}/curl.calls"; exit 22
fi
claims=\$(b64d "\${p}")
if ! jq -e --arg i "${MOCK_CLIENT_ID}" '.iss == \$i and (.exp - .iat) == 600' <<<"\${claims}" >/dev/null; then
  echo "jwt_bad_claims" >>"${MOCK_DIR}/curl.calls"; exit 22
fi
echo "\${method} \${url##*api.github.com}" >>"${MOCK_DIR}/curl.calls"
case "\${method} \${url}" in
  "GET "*/app/installations*) cat "${MOCK_DIR}/installations.json" ;;
  "POST "*/app/installations/777/access_tokens)
    printf '%s\n' "\${data}" >"${MOCK_DIR}/token-request.json"
    printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}\n' "${MOCK_TOKEN}" ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "${MOCK_DIR}/curl"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# $1 optional: path of the hook script to run (default: the repo's).
_run_hook() {
  local script="${1:-${SCRIPT}}"
  run env -u OP_SERVICE_ACCOUNT_TOKEN HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}/bin:${PATH}" \
    CLAUDE_CLI="${MOCK_DIR}/claude" \
    PRE_MERGE_REAL_GH="${MOCK_DIR}/real-gh" \
    PRE_MERGE_OP_BIN="${MOCK_DIR}/op" \
    PRE_MERGE_CURL_BIN="${MOCK_DIR}/curl" \
    PRE_MERGE_APP_DISABLE="${APP_DISABLE:-0}" \
    bash "${script}" pr merge 31 --squash --delete-branch
  [[ -f "${MOCK_DIR}/prompt.txt" ]] || {
    echo "hook never reached the analysis; output: ${output}" >&2
    return 1
  }
  sed -n '/^=== Required CI Checks/,/^=== Non-Required CI Checks/p' \
    "${MOCK_DIR}/prompt.txt" >"${MOCK_DIR}/required.txt"
}

_absent() {
  if grep -qF -- "$1" "$2"; then
    echo "unexpected text '$1' in $2" >&2
    return 1
  fi
}

_assert_unreadable() {
  [[ "${output}" != *"CI status: every required check passed"* ]]
  [[ "${output}" != *"CI read via GitHub App token"* ]]
  grep -q "CI status unreadable" "${MOCK_DIR}/required.txt"
}

@test "app path: FORBIDDEN PAT read -> App token reads the rollup -> CI passed" {
  _run_hook
  [[ "${output}" == *"CI read via GitHub App token"* ]]
  [[ "${output}" == *"CI status: every required check passed"* ]]
  grep -q -- "- claude-review / run-review: COMPLETED (SUCCESS)" "${MOCK_DIR}/required.txt"
  # The JWT verified and both App calls ran, in order.
  [[ "$(cat "${MOCK_DIR}/curl.calls")" == "GET /app/installations?per_page=100"$'\n'"POST /app/installations/777/access_tokens" ]]
  # Least privilege: one repo, read-only scopes, nothing else.
  jq -e '.repositories == ["r"]
    and .permissions == {checks:"read",statuses:"read",pull_requests:"read",metadata:"read"}' \
    "${MOCK_DIR}/token-request.json"
}

@test "no secret in any output: token and JWT absent from log and prompt" {
  _run_hook
  [[ "${output}" == *"CI read via GitHub App token"* ]]
  printf '%s' "${output}" >"${MOCK_DIR}/out.txt"
  _absent "${MOCK_TOKEN}" "${MOCK_DIR}/out.txt"
  _absent "${MOCK_TOKEN}" "${MOCK_DIR}/prompt.txt"
  # Every JWT starts with the base64url of '{"' = eyJ.
  _absent "eyJ" "${MOCK_DIR}/out.txt"
  _absent "eyJ" "${MOCK_DIR}/prompt.txt"
  _absent "BEGIN" "${MOCK_DIR}/out.txt"
  # The token reached the real gh only through the environment, never argv.
  _absent "${MOCK_TOKEN}" "${MOCK_DIR}/real-gh.calls"
}

@test "1Password unreadable -> fallback to default credentials -> unreadable, not passed" {
  echo fail >"${MOCK_DIR}/op.mode"
  _run_hook
  _assert_unreadable
  [[ "${output}" == *"App token unavailable: cannot read the App client ID from 1Password"* ]]
  [[ "${output}" == *"using default gh credentials"* ]]
  [[ ! -f "${MOCK_DIR}/curl.calls" ]]
}

@test "flattened (invalid) private key -> fallback -> unreadable, not passed" {
  echo badkey >"${MOCK_DIR}/op.mode"
  _run_hook
  _assert_unreadable
  [[ "${output}" == *"App token unavailable: the App private key is invalid"* ]]
  [[ ! -f "${MOCK_DIR}/curl.calls" ]]
}

@test "App not installed on the owner -> fallback -> unreadable, not passed" {
  printf '%s\n' '[{"id":5,"account":{"login":"someone-else"}}]' >"${MOCK_DIR}/installations.json"
  _run_hook
  _assert_unreadable
  [[ "${output}" == *"App token unavailable: the App is not installed on o"* ]]
}

@test "check-runs read fails with the App token -> fallback -> unreadable, not passed" {
  touch "${MOCK_DIR}/check-runs.403"
  _run_hook
  _assert_unreadable
  [[ "${output}" == *"App token minted, but the rollup read failed"* ]]
}

@test "rollup with more than one page -> not trusted as partial -> unreadable" {
  # total_count beyond the one page fetched.
  sed 's/"total_count":1/"total_count":150/' "${MOCK_DIR}/check-runs.json" >"${MOCK_DIR}/c2.json"
  mv "${MOCK_DIR}/c2.json" "${MOCK_DIR}/check-runs.json"
  _run_hook
  _assert_unreadable
}

@test "PRE_MERGE_APP_DISABLE=1 -> 1Password never called -> unreadable" {
  APP_DISABLE=1 _run_hook
  _assert_unreadable
  [[ "${output}" == *"App token unavailable: disabled by PRE_MERGE_APP_DISABLE"* ]]
  [[ ! -f "${MOCK_DIR}/op.calls" ]]
}

@test "rollup readable with default credentials -> App path never runs" {
  touch "${MOCK_DIR}/rollup_readable"
  _run_hook
  [[ "${output}" == *"CI status: every required check passed"* ]]
  [[ "${output}" != *"App token"* ]]
  [[ ! -f "${MOCK_DIR}/op.calls" ]]
}

@test "lib-app-token.sh not installed -> hook still runs, fails closed" {
  # A machine that pulled the new hook but has not re-run install.sh.
  mkdir -p "${MOCK_DIR}/hookcopy"
  cp "${SCRIPT}" "${MOCK_DIR}/hookcopy/pre-merge-review.sh"
  cp "${BATS_TEST_DIRNAME}/../hooks/lib-review-issues.sh" "${MOCK_DIR}/hookcopy/"
  _run_hook "${MOCK_DIR}/hookcopy/pre-merge-review.sh"
  _assert_unreadable
  [[ "${output}" == *"App token unavailable: lib-app-token.sh not installed"* ]]
}

@test "app_token_find_real_gh skips script wrappers on PATH" {
  mkdir -p "${MOCK_DIR}/wrap" "${MOCK_DIR}/realbin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${MOCK_DIR}/wrap/gh"
  chmod +x "${MOCK_DIR}/wrap/gh"
  cp /bin/ls "${MOCK_DIR}/realbin/gh"
  cat >"${MOCK_DIR}/find.sh" <<EOF
source "${BATS_TEST_DIRNAME}/../hooks/lib-app-token.sh"
app_token_find_real_gh
EOF
  run env -u PRE_MERGE_REAL_GH PATH="${MOCK_DIR}/wrap:${MOCK_DIR}/realbin:/usr/bin:/bin" \
    "${BASH}" "${MOCK_DIR}/find.sh"
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == "${MOCK_DIR}/realbin/gh" ]]
}

@test "commit status (StatusContext) from REST maps into the rollup: failure -> not passed" {
  printf '%s\n' '{"total_count":0,"check_runs":[]}' >"${MOCK_DIR}/check-runs.json"
  printf '%s\n' '{"state":"failure","total_count":1,"statuses":[{"context":"claude-review / run-review","state":"failure"}]}' \
    >"${MOCK_DIR}/status.json"
  _run_hook
  [[ "${output}" == *"CI read via GitHub App token"* ]]
  [[ "${output}" != *"CI status: every required check passed"* ]]
  grep -q -- "- claude-review / run-review: COMPLETED (FAILURE)" "${MOCK_DIR}/required.txt"
}
