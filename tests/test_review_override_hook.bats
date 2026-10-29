#!/usr/bin/env bats
# hook-review-override.sh: a prompt `override <code>` lets one blocked review through.
#
# run-review.sh writes a pending record per blocked review; the hook moves it
# to the approved store. Every path here is under BATS_TEST_TMPDIR.
#
# Run: bats tests/test_review_override_hook.bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-review-override.sh"

setup() {
  export HOME="${BATS_TEST_TMPDIR}/home"
  export REVIEW_STATE_DIR="${BATS_TEST_TMPDIR}/state"
  export REVIEW_OVERRIDE_DIR="${BATS_TEST_TMPDIR}/approved"
  PENDING="${REVIEW_STATE_DIR}/review-overrides/pending"
  mkdir -p "${HOME}" "${PENDING}"
}

# _code <mode> <diff_hash>: the code run-review.sh prints for that target.
_code() {
  printf '%s\n%s\n' "$1" "$2" | shasum -a 256 | cut -c1-6
}

# _pending <mode> <diff_hash> [created]: write a pending record as run-review does; print its code.
_pending() {
  local code created="${3:-$(date +%s)}"
  code="$(_code "$1" "$2")"
  printf 'code=%s\nmode=%s\ndiff_hash=%s\nrepo=/r/alpha\nbranch=feat\ncreated=%s\nsummary=code-reviewer: FAIL\n' \
    "${code}" "$1" "$2" "${created}" >"${PENDING}/${code}"
  printf '%s\n' "${code}"
}

# _prompt <text>: run the hook as Claude Code does.
_prompt() {
  run bash -c 'jq -n --arg p "$1" "{hook_event_name: \"UserPromptSubmit\", prompt: \$p}" | "$2"' _ "$1" "${HOOK}"
}

H1="$(printf 'a%.0s' {1..64})"
H2="$(printf 'b%.0s' {1..64})"

@test "a matching code approves and removes the pending record" {
  code="$(_pending commit "${H1}")"
  _prompt "override ${code}"
  [ "${status}" -eq 0 ]
  [ -f "${REVIEW_OVERRIDE_DIR}/${code}" ]
  [ ! -e "${PENDING}/${code}" ]
  grep -q "^diff_hash=${H1}$" "${REVIEW_OVERRIDE_DIR}/${code}"
  grep -q '^mode=commit$' "${REVIEW_OVERRIDE_DIR}/${code}"
  grep -Eq '^approved=[0-9]+$' "${REVIEW_OVERRIDE_DIR}/${code}"
}

@test "reply is the systemMessage plus additionalContext shape" {
  code="$(_pending commit "${H1}")"
  _prompt "override ${code}"
  [ "$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.hookEventName')" = "UserPromptSubmit" ]
  msg="$(printf '%s' "${output}" | jq -r '.systemMessage')"
  [ "$(printf '%s' "${output}" | jq -r '.hookSpecificOutput.additionalContext')" = "${msg}" ]
  [[ "${msg}" == *"approved ${code}"* ]]
  [[ "${msg}" == *"code-reviewer: FAIL"* ]]
  [[ "${msg}" == *"/r/alpha"* ]]
}

@test "case, leading space and several codes" {
  c1="$(_pending commit "${H1}")"
  c2="$(_pending full-diff "${H2}")"
  _prompt "
   OVERRIDE ${c1^^}, ${c2} thanks"
  [ "${status}" -eq 0 ]
  [ -f "${REVIEW_OVERRIDE_DIR}/${c1}" ]
  [ -f "${REVIEW_OVERRIDE_DIR}/${c2}" ]
}

@test "an unknown code approves nothing" {
  code="$(_pending commit "${H1}")"
  wrong=ffffff
  [ "${code}" != "${wrong}" ] || wrong=eeeeee
  _prompt "override ${wrong}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing approved"* ]]
  [ -z "$(ls -A "${REVIEW_OVERRIDE_DIR}" 2>/dev/null)" ]
  [ -f "${PENDING}/${code}" ]
}

@test "one good code and one unknown code approve nothing" {
  code="$(_pending commit "${H1}")"
  wrong=ffffff
  [ "${code}" != "${wrong}" ] || wrong=eeeeee
  _prompt "override ${code} ${wrong}"
  [[ "${output}" == *"nothing approved"* ]]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
}

@test "a mistyped extra code approves nothing" {
  code="$(_pending commit "${H1}")"
  for p in "override ${code} zz12zz" "override ${code} 12345" "override ${code}, abc"; do
    _prompt "${p}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"nothing approved"* ]]
    [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
  done
}

@test "prompts that are not an override are a silent no-op" {
  code="$(_pending commit "${H1}")"
  for p in "please override ${code}" "override" "override ${code}0" "override ${code:0:5}" \
    "overrides ${code}" "looks good" ""; do
    _prompt "${p}"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
  done
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
}

@test "the text gate's approve word does not trigger it" {
  code="$(_pending commit "${H1}")"
  _prompt "approve ${code}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
  [ -f "${PENDING}/${code}" ]
}

@test "a pending record whose hash does not give its code approves nothing" {
  code="$(_pending commit "${H1}")"
  sed -i.bak "s/^diff_hash=.*/diff_hash=${H2}/" "${PENDING}/${code}"
  _prompt "override ${code}"
  [[ "${output}" == *"nothing approved"* ]]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
}

@test "an expired pending record approves nothing" {
  code="$(_pending commit "${H1}" 1)"
  _prompt "override ${code}"
  [[ "${output}" == *"nothing approved"* ]]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
}

@test "expired approvals are pruned through the injected rm" {
  mkdir -p "${REVIEW_OVERRIDE_DIR}"
  printf 'code=abcdef\napproved=1\n' >"${REVIEW_OVERRIDE_DIR}/abcdef"
  fresh="$(_pending commit "${H1}")"
  stub="${BATS_TEST_TMPDIR}/rm-stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/rm.log"\nexec rm "$@"\n' "${BATS_TEST_TMPDIR}" >"${stub}"
  chmod +x "${stub}"
  REVIEW_RM_BIN="${stub}" _prompt "override ${fresh}"
  grep -q "${REVIEW_OVERRIDE_DIR}/abcdef" "${BATS_TEST_TMPDIR}/rm.log"
  [ ! -e "${REVIEW_OVERRIDE_DIR}/abcdef" ]
  [ -f "${REVIEW_OVERRIDE_DIR}/${fresh}" ]
}

@test "bad JSON exits 0" {
  run bash -c 'printf "not json" | "$1"' _ "${HOOK}"
  [ "${status}" -eq 0 ]
}

@test "a code-shaped word after other punctuation approves nothing" {
  c1="$(_pending commit "${H1}")"
  c2="$(_pending full-diff "${H2}")"
  _prompt "override ${c1} - ${c2}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"nothing approved"* ]]
  [ -z "$(ls -A "${REVIEW_OVERRIDE_DIR}" 2>/dev/null)" ]
}

@test "a pending record with a malformed hash approves nothing" {
  code="$(_code commit short)"
  printf 'code=%s\nmode=commit\ndiff_hash=short\ncreated=%s\n' "${code}" "$(date +%s)" >"${PENDING}/${code}"
  _prompt "override ${code}"
  [[ "${output}" == *"not well formed"* ]]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${code}" ]
}

@test "a stray approved= line in a pending record is replaced, not kept" {
  code="$(_pending commit "${H1}")"
  printf 'approved=1\n' >>"${PENDING}/${code}"
  _prompt "override ${code}"
  [ "$(grep -c '^approved=' "${REVIEW_OVERRIDE_DIR}/${code}")" -eq 1 ]
  ! grep -q '^approved=1$' "${REVIEW_OVERRIDE_DIR}/${code}"
}

@test "a failed move of the second code rolls back the first" {
  c1="$(_pending commit "${H1}")"
  c2="$(_pending full-diff "${H2}")"
  stub="${BATS_TEST_TMPDIR}/mv-stub"
  cat >"${stub}" <<'STUB'
#!/usr/bin/env bash
[[ "${*: -1}" == */"${FAIL_CODE}" ]] && exit 1
exec mv "$@"
STUB
  chmod +x "${stub}"
  FAIL_CODE="${c2}" REVIEW_MV_BIN="${stub}" _prompt "override ${c1} ${c2}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"rolled back ${c1}"* ]]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${c1}" ]
  [ ! -e "${REVIEW_OVERRIDE_DIR}/${c2}" ]
  [ -z "$(ls -A "${REVIEW_OVERRIDE_DIR}" 2>/dev/null)" ]
  [ -f "${PENDING}/${c1}" ]
}
