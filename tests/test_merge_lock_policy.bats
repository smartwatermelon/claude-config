#!/usr/bin/env bats
# merge-lock.sh policy and its use in pre-merge-review.sh (dev-env#176).

# Run: bats tests/test_merge_lock_policy.bats

ROOT="${BATS_TEST_DIRNAME}/.."
LOCK="${ROOT}/hooks/merge-lock.sh"
PRE_MERGE="${ROOT}/hooks/pre-merge-review.sh"

setup() {
  unset BASH_ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  unset -f gh 2>/dev/null || true
  export -n gh 2>/dev/null || true
  TMP_HOME="$(mktemp -d)"
  export HOME="${TMP_HOME}"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CEILING_DIRECTORIES="${TMP_HOME}"

  # A stand-in claude-config checkout on main, holding the shipped policy, deployed the way install.sh does.
  CC="${TMP_HOME}/claude-config"
  mkdir -p "${CC}" "${HOME}/.claude/hooks" "${HOME}/.claude/merge-locks"
  git -C "${CC}" init -q -b main
  git -C "${CC}" remote add origin git@github.com:smartwatermelon/claude-config.git
  cp "${ROOT}/merge-lock-policy.conf" "${CC}/merge-lock-policy.conf"
  git -C "${CC}" add merge-lock-policy.conf
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -m policy
  ln -s "${CC}/merge-lock-policy.conf" "${HOME}/.claude/merge-lock-policy.conf"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

# policy <repo> <author>: run the real merge-lock.sh policy.
policy() {
  run "${LOCK}" policy --repo "$1" --author "$2"
}

# --- the decisions ---------------------------------------------------------

@test "everyday repo is exempt" {
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == exempt$'\t'* ]]
}

@test "twistedmelonman repo is exempt" {
  policy twistedmelonman/cat-boxen twistedmelonman
  [[ "${output}" == exempt$'\t'* ]]
}

@test "the four infrastructure repos stay locked" {
  local r
  for r in claude-config dotfiles github-workflows claude-wrapper; do
    policy "smartwatermelon/${r}" twistedmelonman
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == lock$'\t'* ]]
  done
}

@test "the Netlify sites stay locked" {
  policy smartwatermelon/projectinsomnia twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
  policy smartwatermelon/crazy-larry twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
}

@test "every beacon-biosignals repo stays locked" {
  policy beacon-biosignals/anything dependabot
  [[ "${output}" == lock$'\t'* ]]
}

@test "nightowlstudiollc stays locked, by its own owner rule" {
  policy nightowlstudiollc/kebab-tax-netlify twistedmelonman
  [[ "${output}" == lock$'\t'*$'\t'owner=nightowlstudiollc ]]
}

@test "an andrewmrich-authored PR in an otherwise exempt repo stays locked" {
  policy smartwatermelon/spokane-snow andrewmrich
  [[ "${output}" == lock$'\t'*$'\t'author=andrewmrich ]]
}

@test "beacon-workspace is exempt, andrewmrich-authored or not" {
  policy andrewmrich/beacon-workspace andrewmrich
  [[ "${output}" == exempt$'\t'* ]]
  policy AndrewMRich/Beacon-Workspace app/dependabot
  [[ "${output}" == exempt$'\t'* ]]
}

@test "matching ignores case" {
  policy SmartWatermelon/Claude-Config twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
}

# --- fail closed ------------------------------------------------------------

@test "an unknown author is an error, never exempt" {
  run "${LOCK}" policy --repo smartwatermelon/dev-env --author ""
  [[ "${status}" -ne 0 ]]
}

@test "no deployed policy is an error" {
  rm "${HOME}/.claude/merge-lock-policy.conf"
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
  [[ "${output}" != exempt* ]]
}

@test "a plain file in place of the symlink is refused" {
  rm "${HOME}/.claude/merge-lock-policy.conf"
  printf '* exempt\n' >"${HOME}/.claude/merge-lock-policy.conf"
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${status}" -ne 0 ]]
}

@test "an uncommitted edit to the checkout does not count" {
  printf 'repo=smartwatermelon/claude-config exempt\n' >"${CC}/merge-lock-policy.conf"
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
}

@test "a checkout on another branch is refused" {
  git -C "${CC}" checkout -q -b claude/x
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
}

@test "a checkout with another origin is refused" {
  git -C "${CC}" remote set-url origin git@github.com:someone/claude-config.git
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
}

@test "a bad line anywhere fails the whole policy" {
  printf 'repo=smartwatermelon/dev-env exempt\nowner=x maybe\n' >"${CC}/merge-lock-policy.conf"
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -am bad
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
}

# --- an agent cannot write the list ----------------------------------------

@test "Write/Edit hook blocks the deployed policy file" {
  run bash -c 'printf "{\"tool_input\":{\"file_path\":\"%s\"}}" "$1" | "$2"' _ \
    "${HOME}/.claude/merge-lock-policy.conf" "${ROOT}/scripts/hook-block-merge-locks-write.sh"
  [[ "${status}" -eq 2 ]]
}

@test "Bash hook blocks a write to the deployed policy file" {
  local cmd='echo "* exempt" > ~/.claude/merge-lock-policy.conf'
  run bash -c 'jq -n --arg c "$1" "{tool_input:{command:\$c}}" | "$2"' _ \
    "${cmd}" "${ROOT}/scripts/hook-block-gate-dir-write.sh"
  [[ "${status}" -eq 2 ]]
}

@test "Bash hook blocks merge-lock authorize, so the agent cannot lock-then-merge either" {
  local cmd='merge-lock authorize 5 ok --repo smartwatermelon/claude-config'
  run bash -c 'jq -n --arg c "$1" "{tool_input:{command:\$c}}" | "$2"' _ \
    "${cmd}" "${ROOT}/scripts/hook-block-merge-lock-authorize.sh"
  [[ "${status}" -eq 2 ]]
}

# --- pre-merge-review.sh ----------------------------------------------------

# _pre_merge <repo> <author> <verdict>: run pre-merge-review.sh with the real merge-lock.sh and stub gh/claude.
_pre_merge() {
  local bin="${TMP_HOME}/bin"
  mkdir -p "${bin}"
  ln -sf "${LOCK}" "${HOME}/.claude/hooks/merge-lock.sh"
  cat >"${bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  printf '%s\n' '{"number":7,"title":"t","state":"OPEN","reviews":[],"comments":[],"reviewDecision":"","statusCheckRollup":[],"baseRefName":"main","url":"https://github.com/$1/pull/7","author":{"login":"$2"}}'
  exit 0
fi
echo "[]"
EOF
  cat >"${bin}/claude" <<EOF
#!/usr/bin/env bash
touch "${TMP_HOME}/claude-ran"
printf 'VERDICT: %s\n' "$3"
EOF
  chmod +x "${bin}/gh" "${bin}/claude"
  run env PATH="${bin}:${PATH}" CLAUDE_CLI="${bin}/claude" "${PRE_MERGE}" pr merge 7 --repo "$1" --squash --delete-branch
}

@test "exempt repo skips the lock but still runs the review" {
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  [[ "${output}" != *"MERGE AUTHORIZATION REQUIRED"* ]]
  [[ "${output}" == *"Merge lock not required"* ]]
  [[ -f "${TMP_HOME}/claude-ran" ]]
  [[ "${status}" -eq 0 ]]
}

@test "exempt repo is still blocked by a BLOCK_MERGE review" {
  _pre_merge smartwatermelon/dev-env twistedmelonman BLOCK_MERGE
  [[ -f "${TMP_HOME}/claude-ran" ]]
  [[ "${status}" -ne 0 ]]
}

@test "andrewmrich-authored PR in an exempt repo still needs the lock" {
  _pre_merge smartwatermelon/spokane-snow andrewmrich SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"MERGE AUTHORIZATION REQUIRED"* ]]
  [[ ! -f "${TMP_HOME}/claude-ran" ]]
}

@test "locked repo still needs the lock" {
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"MERGE AUTHORIZATION REQUIRED"* ]]
}

@test "no deployed policy: every repo needs the lock" {
  rm "${HOME}/.claude/merge-lock-policy.conf"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"MERGE AUTHORIZATION REQUIRED"* ]]
}
