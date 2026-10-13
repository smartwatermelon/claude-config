#!/usr/bin/env bash
# Mints a GitHub App token so pre-merge-review.sh can read private-repo CI (#687). Secrets stay out of argv/logs/disk.

# App identity: the one place to change. Use the key attachment; a pasted PEM field is flattened.
PRE_MERGE_APP_OP_ITEM="${PRE_MERGE_APP_OP_ITEM:-op://Automation/DIGEST_APP}"
PRE_MERGE_APP_CLIENT_ID_FIELD="${PRE_MERGE_APP_CLIENT_ID_FIELD:-client_id}"
PRE_MERGE_APP_KEY_FILE="${PRE_MERGE_APP_KEY_FILE:-dependabot-digest-swm.2026-10-01.private-key.pem}"

# Test seams: tests point these at mocks so they never reach 1Password or GitHub.
PRE_MERGE_OP_BIN="${PRE_MERGE_OP_BIN:-op}"
PRE_MERGE_CURL_BIN="${PRE_MERGE_CURL_BIN:-curl}"
PRE_MERGE_OPENSSL_BIN="${PRE_MERGE_OPENSSL_BIN:-openssl}"
PRE_MERGE_GITHUB_API="${PRE_MERGE_GITHUB_API:-https://api.github.com}"
# Bounds each `op read`: without a service account, op can wait on a desktop prompt.
PRE_MERGE_OP_TIMEOUT="${PRE_MERGE_OP_TIMEOUT:-20}"

# Prints a failure reason on stderr. Reasons never contain a secret.
_app_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

# base64url, no padding, of file $1 (a file, so callers pass a process substitution).
_app_b64url() {
  local s
  s=$("${PRE_MERGE_OPENSSL_BIN}" base64 -A -in "$1" 2>/dev/null) || return 1
  s="${s//+/-}"
  s="${s//\//_}"
  printf '%s' "${s//=/}"
}

# `op read <ref>`, time-bounded when timeout or gtimeout exists.
_app_op_read() {
  local ref="$1" t
  for t in timeout gtimeout; do
    if command -v "${t}" >/dev/null 2>&1; then
      "${t}" "${PRE_MERGE_OP_TIMEOUT}" "${PRE_MERGE_OP_BIN}" read "${ref}" 2>/dev/null
      return
    fi
  done
  "${PRE_MERGE_OP_BIN}" read "${ref}" 2>/dev/null
}

# First non-script gh on PATH. The gh wrapper (a script) swaps GH_TOKEN for its PAT on private repos.
app_token_find_real_gh() {
  if [[ -n "${PRE_MERGE_REAL_GH:-}" ]]; then
    printf '%s\n' "${PRE_MERGE_REAL_GH}"
    return 0
  fi
  local IFS=':' dir candidate head
  for dir in ${PATH}; do
    candidate="${dir}/gh"
    [[ -x "${candidate}" && ! -d "${candidate}" ]] || continue
    head=$(LC_ALL=C head -c 2 "${candidate}" 2>/dev/null || true)
    [[ "${head}" == "#!" ]] && continue
    printf '%s\n' "${candidate}"
    return 0
  done
  return 1
}

# curl with JWT $1 as a Bearer header via --config process substitution; remaining args go to curl.
_app_curl() {
  local jwt="$1"
  shift
  "${PRE_MERGE_CURL_BIN}" -sS --fail --max-time 15 \
    --config <(printf 'header = "Authorization: Bearer %s"\n' "${jwt}") \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$@" 2>/dev/null
}

# app_token_mint OWNER REPO: read-only token for REPO on stdout; on failure, a reason on stderr.
app_token_mint() {
  local owner="$1" repo="$2"
  if [[ -z "${owner}" || -z "${repo}" ]]; then
    _app_fail "owner/repo unknown"
    return 1
  fi
  if ! command -v "${PRE_MERGE_OP_BIN}" >/dev/null 2>&1; then
    _app_fail "1Password CLI (op) not available"
    return 1
  fi

  local client_id
  if ! client_id=$(_app_op_read "${PRE_MERGE_APP_OP_ITEM}/${PRE_MERGE_APP_CLIENT_ID_FIELD}") || [[ -z "${client_id}" ]]; then
    _app_fail "cannot read the App client ID from 1Password (${PRE_MERGE_APP_OP_ITEM})"
    return 1
  fi
  if [[ ! "${client_id}" =~ ^[A-Za-z0-9.]+$ ]]; then
    _app_fail "App client ID read from 1Password is malformed"
    return 1
  fi

  local key
  if ! key=$(_app_op_read "${PRE_MERGE_APP_OP_ITEM}/${PRE_MERGE_APP_KEY_FILE}") || [[ -z "${key}" ]]; then
    _app_fail "cannot read the App private key from 1Password (${PRE_MERGE_APP_OP_ITEM})"
    return 1
  fi

  local now header payload unsigned sig jwt
  now=$(date +%s)
  header=$(_app_b64url <(printf '%s' '{"alg":"RS256","typ":"JWT"}'))
  payload=$(_app_b64url <(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "${client_id}"))
  unsigned="${header}.${payload}"
  # A failed signature yields no bytes, so an empty sig is the failure test.
  sig=$(_app_b64url <("${PRE_MERGE_OPENSSL_BIN}" dgst -sha256 -binary \
    -sign <(printf '%s\n' "${key}") <(printf '%s' "${unsigned}") 2>/dev/null || true)) || sig=""
  if [[ -z "${sig}" || -z "${header}" || -z "${payload}" ]]; then
    key=""
    _app_fail "the App private key is invalid (openssl could not sign)"
    return 1
  fi
  key=""
  jwt="${unsigned}.${sig}"

  local installations inst_id
  if ! installations=$(_app_curl "${jwt}" "${PRE_MERGE_GITHUB_API}/app/installations?per_page=100"); then
    _app_fail "GitHub rejected the App JWT or was unreachable (GET /app/installations)"
    return 1
  fi
  inst_id=$(jq -r --arg o "${owner}" \
    '[.[]? | select((.account.login // "" | ascii_downcase) == ($o | ascii_downcase)) | .id][0] // empty' \
    <<<"${installations}" 2>/dev/null || true)
  if [[ ! "${inst_id}" =~ ^[0-9]+$ ]]; then
    _app_fail "the App is not installed on ${owner}"
    return 1
  fi

  local body resp token
  body=$(jq -cn --arg r "${repo}" '{repositories: [$r],
    permissions: {checks: "read", statuses: "read", pull_requests: "read", metadata: "read"}}')
  if ! resp=$(_app_curl "${jwt}" -X POST --data "${body}" \
    "${PRE_MERGE_GITHUB_API}/app/installations/${inst_id}/access_tokens"); then
    _app_fail "GitHub refused an installation token for ${owner}/${repo} (POST access_tokens)"
    return 1
  fi
  jwt=""
  token=$(jq -r '.token // empty' <<<"${resp}" 2>/dev/null || true)
  resp=""
  if [[ -z "${token}" ]]; then
    _app_fail "the access_tokens response carried no token"
    return 1
  fi
  printf '%s\n' "${token}"
}
