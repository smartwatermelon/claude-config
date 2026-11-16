#!/usr/bin/env bash

# Copies the OpenAI reviewer API key (monthly API credit grant) from 1Password to the login Keychain for run-review.sh.

# Run once per machine: login-keychain items do not sync. Twin of install-reviewer-api-key.sh.

# Rotate by re-running this, not in Keychain Access: its `apple:` partition list blocks `security` (#846).

set -euo pipefail

# The item keeps its CODEX_REVIEWER name; Codex itself cannot use credit-grant keys.
OP_REF="${OPENAI_REVIEWER_KEY_OP_REF:-op://Automation/CODEX_REVIEWER/CODEX_REVIEWER}"
SERVICE="${OPENAI_REVIEWER_KEY_SERVICE:-openai-reviewer-api-key}"
# Same account fallback as run-review.sh, so both name the same item.
ACCOUNT="${USER:-$(id -un)}"
KEYCHAIN="${OPENAI_REVIEWER_KEY_KEYCHAIN:-${HOME}/Library/Keychains/login.keychain-db}"
BACKUP_DIR="${OPENAI_REVIEWER_KEY_BACKUP_DIR:-${HOME}/.local/state/keychain-backups}"
# Test seams: tests point these at mocks so they never reach 1Password.
OP_BIN="${OPENAI_REVIEWER_KEY_OP_BIN:-op}"
SECURITY_BIN="${OPENAI_REVIEWER_KEY_SECURITY_BIN:-security}"
CURL_BIN="${OPENAI_REVIEWER_KEY_CURL_BIN:-curl}"
API_BASE="${OPENAI_REVIEWER_KEY_API_BASE:-https://api.openai.com}"

die() {
  printf 'install-openai-reviewer-api-key: %s\n' "$*" >&2
  exit 1
}

[[ -f "${KEYCHAIN}" ]] || die "keychain not found: ${KEYCHAIN}"

# 1. Check before the backup. Project keys are sk-proj-; older user keys are plain sk-.
key=$("${OP_BIN}" read "${OP_REF}") || die "op read failed: ${OP_REF}"
# sk-ant- also matches the loose pattern; an Anthropic key pasted here is caught by name.
[[ "${key}" =~ ^sk-(proj-)?[A-Za-z0-9_-]+$ && "${key}" != sk-ant-* ]] \
  || die "value at ${OP_REF} is not an OpenAI API key (length ${#key})"
# An admin key cannot call the Responses API.
[[ "${key}" != sk-admin-* ]] \
  || die "value at ${OP_REF} is an admin key, not an API key"
# A shape match is a label, not proof. /v1/models is free and needs a live key.
# The key goes in on stdin (-H @-), never in argv.
status=$(printf 'Authorization: Bearer %s\n' "${key}" \
  | "${CURL_BIN}" -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- \
      "${API_BASE}/v1/models") || status="curl-failed"
[[ "${status}" == "200" ]] || die "key at ${OP_REF} rejected by ${API_BASE}/v1/models (HTTP ${status})"

# 2. Backup. The PID suffix keeps two runs in one second from sharing a name.
mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
backup="${BACKUP_DIR}/$(basename "${KEYCHAIN}").$(date +%Y%m%dT%H%M%S).$$"
cp -p "${KEYCHAIN}" "${backup}"
chmod 600 "${backup}"
cmp -s "${KEYCHAIN}" "${backup}" || die "backup differs from source: ${backup}"
[[ -s "${backup}" ]] || die "backup is empty: ${backup}"
printf 'Backup: %s\n' "${backup}"

# 3. Write via `security -i` stdin: no argv exposure, no 128-char -w prompt truncation
#    (this key is ~164 chars). -U updates.
printf 'add-generic-password -U -a %s -s %s -w %s %s\n' \
  "${ACCOUNT}" "${SERVICE}" "${key}" "${KEYCHAIN}" \
  | "${SECURITY_BIN}" -i >/dev/null \
  || die "security add-generic-password failed; backup at ${backup}"

# 4. Verify.
stored=$("${SECURITY_BIN}" find-generic-password -a "${ACCOUNT}" -s "${SERVICE}" -w "${KEYCHAIN}") \
  || die "item not found after write; backup at ${backup}"
[[ "${stored}" == "${key}" ]] \
  || die "stored value differs from 1Password (stored length ${#stored}, expected ${#key}); backup at ${backup}"

printf 'Stored %s (account %s, length %d) in %s\n' "${SERVICE}" "${ACCOUNT}" "${#stored}" "${KEYCHAIN}"
