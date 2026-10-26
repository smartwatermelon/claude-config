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
  # Agent-written review records (#779): never the caller's real state dir.
  export REVIEW_STATE_DIR="${TMP_HOME}/state"
  export PENDING_ISSUES_DIR="${REVIEW_STATE_DIR}/pending-issues"
  EXEMPT_LOG="${REVIEW_STATE_DIR}/exempt.tsv"
  LEGACY_EXEMPT_LOG="${HOME}/.claude/merge-locks/exempt.tsv"
  mkdir -p "${REVIEW_STATE_DIR}"

  # A stand-in claude-config checkout on main, holding the shipped policy, deployed the way install.sh does.
  CC="${TMP_HOME}/claude-config"
  mkdir -p "${CC}" "${HOME}/.claude/hooks" "${HOME}/.claude/merge-locks"
  git -C "${CC}" init -q -b main
  git -C "${CC}" remote add origin git@github.com:smartwatermelon/claude-config.git
  cp "${ROOT}/merge-lock-policy.conf" "${CC}/merge-lock-policy.conf"
  git -C "${CC}" add merge-lock-policy.conf
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -m policy
  git -C "${CC}" update-ref refs/remotes/origin/main HEAD
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

@test "an outcome that only looks like refuse is still an error" {
  # Adding refuse must not loosen the validator: a misspelled outcome fails the whole file.
  printf 'owner=x refused\n* exempt\n' >"${CC}/merge-lock-policy.conf"
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -am typo
  git -C "${CC}" update-ref refs/remotes/origin/main HEAD
  policy x/y twistedmelonman
  [[ "${status}" -ne 0 ]]
  [[ "${output}" != refuse* && "${output}" != exempt* ]]
}

@test "every beacon-biosignals repo is refused, whoever authored the PR" {
  local a
  for a in andrewmrich dependabot app/dependabot twistedmelonman; do
    policy beacon-biosignals/anything "${a}"
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == refuse$'\t'*$'\t'owner=beacon-biosignals ]]
  done
  policy Beacon-Biosignals/Anything andrewmrich
  [[ "${output}" == refuse$'\t'* ]]
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

@test "policy is read from main while another branch is checked out" {
  git -C "${CC}" checkout -q -b claude/x
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == exempt$'\t'* ]]
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
}

@test "known-bad: an edit committed only on the checked-out branch does not count" {
  git -C "${CC}" checkout -q -b claude/x
  printf '* exempt\n' >"${CC}/merge-lock-policy.conf"
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -am branch-only
  # Even with origin/main moved to the branch commit, local main is what is read.
  git -C "${CC}" update-ref refs/remotes/origin/main HEAD
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == lock$'\t'* ]]
}

@test "a detached HEAD still reads main" {
  git -C "${CC}" checkout -q --detach
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${output}" == lock$'\t'* ]]
}

@test "a checkout with no local main is an error, never exempt" {
  git -C "${CC}" checkout -q -b claude/x
  git -C "${CC}" branch -q -D main
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
  [[ "${output}" != exempt* ]]
}

@test "a checkout with another origin is refused" {
  git -C "${CC}" remote set-url origin git@github.com:someone/claude-config.git
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
}

@test "an SSH host-alias origin is accepted" {
  local u
  for u in git@github-smartwatermelon:smartwatermelon/claude-config.git \
    git@github-smartwatermelon:smartwatermelon/claude-config \
    git@github-a.b_c-1:smartwatermelon/claude-config.git; do
    git -C "${CC}" remote set-url origin "${u}"
    policy smartwatermelon/dev-env twistedmelonman
    [[ "${status}" -eq 0 ]]
    [[ "${output}" == exempt$'\t'* ]]
  done
}

@test "an SSH host-alias origin for another owner or repo is refused" {
  local u
  for u in git@github-x:someone/claude-config.git \
    git@github-smartwatermelon:smartwatermelon/claude-config-fork.git \
    git@github-:smartwatermelon/claude-config.git \
    'git@github-a/b:smartwatermelon/claude-config.git' \
    git@gitlab-x:smartwatermelon/claude-config.git \
    git@github-x:smartwatermelon/claude-config.git.evil; do
    git -C "${CC}" remote set-url origin "${u}"
    policy smartwatermelon/dev-env twistedmelonman
    [[ "${status}" -ne 0 ]]
  done
}

@test "a local commit on main that is not on origin/main is refused" {
  printf '* exempt\n' >"${CC}/merge-lock-policy.conf"
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -am local
  policy smartwatermelon/claude-config twistedmelonman
  [[ "${status}" -ne 0 ]]
  [[ "${output}" != exempt* ]]
}

@test "an origin on another host is refused" {
  git -C "${CC}" remote set-url origin git@evil.example:smartwatermelon/claude-config.git
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${status}" -ne 0 ]]
}

@test "an https origin is accepted" {
  git -C "${CC}" remote set-url origin https://github.com/smartwatermelon/claude-config.git
  policy smartwatermelon/dev-env twistedmelonman
  [[ "${output}" == exempt$'\t'* ]]
}

@test "a bad line anywhere fails the whole policy" {
  printf 'repo=smartwatermelon/dev-env exempt\nowner=x maybe\n' >"${CC}/merge-lock-policy.conf"
  git -C "${CC}" -c user.name=t -c user.email=t@t commit -q -am bad
  git -C "${CC}" update-ref refs/remotes/origin/main HEAD
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

# _pre_merge <repo> <author> <verdict> [findings]: run pre-merge-review.sh with the real merge-lock.sh and stub gh/claude.
# With a 4th arg, the review also reports one non-blocking finding; each `gh issue create` is logged to gh-issues.
_pre_merge() {
  local bin="${TMP_HOME}/bin"
  mkdir -p "${bin}"
  # LOCK_MODE (default link): link the real script; missing, noexec or garbage install something else.
  rm -f "${HOME}/.claude/hooks/merge-lock.sh"
  case "${LOCK_MODE:-link}" in
    link) ln -s "${LOCK}" "${HOME}/.claude/hooks/merge-lock.sh" ;;
    missing) ;;
    noexec)
      cp "${LOCK}" "${HOME}/.claude/hooks/merge-lock.sh"
      chmod 644 "${HOME}/.claude/hooks/merge-lock.sh"
      ;;
    garbage)
      # policy answers with an unparseable line; check always says authorized.
      cat >"${HOME}/.claude/hooks/merge-lock.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == policy ]] && { echo "maybe"; exit 0; }
exit 0
STUB
      chmod +x "${HOME}/.claude/hooks/merge-lock.sh"
      ;;
    *) return 1 ;;
  esac
  cat >"${bin}/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  printf '%s\n' '{"number":7,"title":"t","state":"OPEN","reviews":[],"comments":[],"reviewDecision":"","statusCheckRollup":[],"baseRefName":"main","url":"https://github.com/$1/pull/7","author":{"login":"$2"}}'
  exit 0
fi
if [[ "\$1" == "pr" && "\$2" == "merge" ]]; then
  printf '%s\n' "\$*" >>"${TMP_HOME}/gh-merges"
  exit 0
fi
if [[ "\$1" == "issue" && "\$2" == "create" ]]; then
  printf '%s\n' "\$*" >>"${TMP_HOME}/gh-issues"
  echo "https://github.com/$1/issues/99"
  exit 0
fi
echo "[]"
EOF
  local finding=""
  if [[ -n "${4:-}" ]]; then
    finding=$'\nNON_BLOCKING_ISSUE:\nTITLE: Consider a guard\nSOURCE: code-reviewer\nLOCATION: a.sh:1\nDETAILS: Add a guard.\nEND_ISSUE'
  fi
  cat >"${bin}/claude" <<EOF
#!/usr/bin/env bash
touch "${TMP_HOME}/claude-ran"
printf 'VERDICT: %s\n%s\n' "$3" "${finding}"
EOF
  chmod +x "${bin}/gh" "${bin}/claude"
  run env PATH="${bin}:${PATH}" CLAUDE_CLI="${bin}/claude" "${PRE_MERGE}" pr merge 7 --repo "$1" --squash --delete-branch
}

@test "exempt repo skips the lock but still runs the review" {
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  [[ "${output}" != *"Not merged"* ]]
  [[ "${output}" == *"Merge lock not required"* ]]
  [[ -f "${TMP_HOME}/claude-ran" ]]
  [[ "${status}" -eq 0 ]]
  grep -q $'\tsmartwatermelon/dev-env\t7\ttwistedmelonman\t' "${EXEMPT_LOG}"
}

@test "exempt repo is still blocked by a BLOCK_MERGE review, and nothing is logged" {
  _pre_merge smartwatermelon/dev-env twistedmelonman BLOCK_MERGE
  [[ -f "${TMP_HOME}/claude-ran" ]]
  [[ "${status}" -ne 0 ]]
  [[ ! -s "${EXEMPT_LOG}" ]]
}

@test "andrewmrich-authored PR in an exempt repo still needs the lock" {
  _pre_merge smartwatermelon/spokane-snow andrewmrich SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"[gh] Not merged: smartwatermelon/spokane-snow#7 needs Andrew's approval."* ]]
  [[ ! -f "${TMP_HOME}/claude-ran" ]]
}

@test "locked repo still needs the lock" {
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"[gh] Not merged: smartwatermelon/claude-config#7 needs Andrew's approval."* ]]
  [[ "${output}" != *"authorize"* ]]
}

# --- policy failure refuses ---------------------------------------------------

# _policy_error_line <repo>: the one line a policy failure prints.
_policy_error_line() {
  printf '[gh] Not merged: the merge policy could not be read for %s#7; no agent merges until it is fixed.' "$1"
}

# _valid_lock <repo>: write a lock for PR 7 that merge-lock.sh check accepts.
_valid_lock() {
  local lock="${HOME}/.claude/merge-locks/$1/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\n' "$(date +%s)" >"${lock}"
}

# _assert_policy_refused <repo> <status> <output>: policy-error line, no review, no merge, nothing logged.
_assert_policy_refused() {
  local out="$3"
  [[ "$2" -eq 1 ]]
  [[ "${out}" == *"$(_policy_error_line "$1")"* ]]
  [[ "${out}" != *"needs Andrew's approval"* ]]
  [[ "${out}" != *"Merge authorization verified"* ]]
  [[ "${out}" != *"Merge lock not required"* ]]
  [[ ! -f "${TMP_HOME}/claude-ran" ]]
  [[ ! -e "${TMP_HOME}/gh-merges" ]]
  [[ ! -s "${EXEMPT_LOG}" ]]
}

@test "known-bad: no deployed policy refuses even with a valid lock" {
  _valid_lock smartwatermelon/dev-env
  rm "${HOME}/.claude/merge-lock-policy.conf"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/dev-env "${status}" "${output}"
}

@test "no deployed policy refuses without a lock too" {
  rm "${HOME}/.claude/merge-lock-policy.conf"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/dev-env "${status}" "${output}"
}

@test "known-bad: a missing merge-lock.sh refuses, it does not skip the lock" {
  LOCK_MODE=missing _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/claude-config "${status}" "${output}"
}

@test "known-bad: a non-executable merge-lock.sh refuses, it does not skip the lock" {
  LOCK_MODE=noexec _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/dev-env "${status}" "${output}"
}

@test "known-bad: an unparseable policy answer refuses even when check would pass" {
  LOCK_MODE=garbage _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/dev-env "${status}" "${output}"
}

@test "known-bad: an unknown PR author refuses even with a valid lock" {
  _valid_lock smartwatermelon/claude-config
  _pre_merge smartwatermelon/claude-config "" SAFE_TO_MERGE
  _assert_policy_refused smartwatermelon/claude-config "${status}" "${output}"
}

@test "a policy error prints exactly one stdout line" {
  rm "${HOME}/.claude/merge-lock-policy.conf"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  local bin="${TMP_HOME}/bin"
  run bash -c '"$@" 2>/dev/null' _ env PATH="${bin}:${PATH}" CLAUDE_CLI="${bin}/claude" \
    "${PRE_MERGE}" pr merge 7 --repo smartwatermelon/dev-env --squash --delete-branch
  [[ "${status}" -eq 1 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" == "$(_policy_error_line smartwatermelon/dev-env)" ]]
}

# --- refuse ------------------------------------------------------------------

_refuse_line() {
  printf '[gh] Not merged: %s#7 is merged by Andrew in the GitHub UI after its own approval process; agents do not merge it.' "$1"
}

@test "refused repo: Not merged, no review, no lock prompt" {
  local a
  for a in andrewmrich dependabot twistedmelonman; do
    _pre_merge beacon-biosignals/anything "${a}" SAFE_TO_MERGE
    [[ "${status}" -eq 1 ]]
    [[ "${output}" == *"$(_refuse_line beacon-biosignals/anything)"* ]]
    [[ "${output}" != *"needs Andrew's approval"* ]]
    [[ "${output}" != *"authorize"* ]]
    [[ ! -f "${TMP_HOME}/claude-ran" ]]
  done
}

@test "known-bad: a valid lock does not override refuse" {
  local lock="${HOME}/.claude/merge-locks/beacon-biosignals/anything/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\n' "$(date +%s)" >"${lock}"
  # Prove the lock is one check accepts, so the refusal below is the policy's doing.
  run "${LOCK}" check 7 --repo beacon-biosignals/anything
  [[ "${status}" -eq 0 ]]
  _pre_merge beacon-biosignals/anything andrewmrich SAFE_TO_MERGE
  [[ "${status}" -eq 1 ]]
  [[ "${output}" == *"$(_refuse_line beacon-biosignals/anything)"* ]]
  [[ "${output}" != *"Merge authorization verified"* ]]
  [[ ! -f "${TMP_HOME}/claude-ran" ]]
  [[ ! -e "${TMP_HOME}/gh-merges" ]]
  [[ ! -s "${EXEMPT_LOG}" ]]
}

@test "refuse stdout is exactly one line" {
  _pre_merge beacon-biosignals/anything andrewmrich SAFE_TO_MERGE
  local bin="${TMP_HOME}/bin"
  # stdout only: the line the Bash tool surfaces.
  run bash -c '"$@" 2>/dev/null' _ env PATH="${bin}:${PATH}" CLAUDE_CLI="${bin}/claude" \
    "${PRE_MERGE}" pr merge 7 --repo beacon-biosignals/anything --squash --delete-branch
  [[ "${status}" -eq 1 ]]
  [[ "${#lines[@]}" -eq 1 ]]
  [[ "${lines[0]}" == "$(_refuse_line beacon-biosignals/anything)" ]]
}

@test "known-bad: a policy error on a beacon-biosignals PR refuses even with a valid lock" {
  _valid_lock beacon-biosignals/anything
  rm "${HOME}/.claude/merge-lock-policy.conf"
  _pre_merge beacon-biosignals/anything andrewmrich SAFE_TO_MERGE
  _assert_policy_refused beacon-biosignals/anything "${status}" "${output}"
}

# --- non-blocking issue dedup for exempt merges (#702) ----------------------

# _issue_count: how many times the stub gh was asked to create an issue.
_issue_count() {
  if [[ -f "${TMP_HOME}/gh-issues" ]]; then
    # The issue body spans lines, so count the call prefix, not lines.
    grep -c '^issue create ' "${TMP_HOME}/gh-issues" || true
  else
    echo 0
  fi
}

@test "exempt merge files its non-blocking issue" {
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ "${output}" != *"already filed"* ]]
}

@test "known-bad: a retried exempt merge in the window does not file twice" {
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ "${output}" == *"already filed for smartwatermelon/dev-env#7 in this exempt window"* ]]
  # The retry is still logged, so merge-audit sees the attempt.
  [[ "$(grep -c $'\tsmartwatermelon/dev-env\t7\t' "${EXEMPT_LOG}")" -eq 2 ]]
}

@test "an exempt merge after the window files again" {
  printf '%s\tsmartwatermelon/dev-env\t7\ttwistedmelonman\told\n' "$(($(date +%s) - 7200))" \
    >"${EXEMPT_LOG}"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
}

@test "a recent exempt row for the same PR number in another repo does not skip filing" {
  printf '%s\tsmartwatermelon/other\t7\ttwistedmelonman\tx\n' "$(date +%s)" \
    >"${EXEMPT_LOG}"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "$(_issue_count)" -eq 1 ]]
}

@test "known-bad: a recent exempt row matches the repo case-insensitively" {
  printf '%s\tSmartWatermelon/Dev-Env\t7\ttwistedmelonman\tx\n' "$(date +%s)" \
    >"${EXEMPT_LOG}"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 0 ]]
}

@test "locked merge: files once, then a retry in the auth window skips" {
  local lock="${HOME}/.claude/merge-locks/smartwatermelon/claude-config/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\n' "$(date +%s)" >"${lock}"
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ -s "$(_marker smartwatermelon/claude-config)" ]]
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ "${output}" == *"already filed for PR #7 in this auth window"* ]]
  # A locked merge never writes an exempt row.
  [[ ! -s "${EXEMPT_LOG}" ]]
  [[ ! -e "${LEGACY_EXEMPT_LOG}" ]]
}

# --- agent records stay out of merge-locks (#779) ----------------------------

# _marker <repo>: the issues-filed marker path for PR 7 of <repo>.
_marker() {
  printf '%s/issues-filed/%s/pr-7' "${REVIEW_STATE_DIR}" "$1"
}

@test "known-bad: a merge run never modifies the lock file" {
  local lock="${HOME}/.claude/merge-locks/smartwatermelon/claude-config/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\n' "$(date +%s)" >"${lock}"
  local before
  before=$(cat "${lock}")
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ "$(cat "${lock}")" == "${before}" ]]
  [[ "$(cat "${lock}")" != *ISSUES_CREATED* ]]
}

@test "the issues-filed marker holds the filing time" {
  local lock="${HOME}/.claude/merge-locks/smartwatermelon/claude-config/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\n' "$(date +%s)" >"${lock}"
  local t0
  t0=$(date +%s)
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  local ts
  ts=$(head -1 "$(_marker smartwatermelon/claude-config)")
  [[ "${ts}" =~ ^[0-9]+$ ]]
  ((ts >= t0 && ts <= $(date +%s)))
}

@test "a marker inside the window skips filing" {
  _valid_lock smartwatermelon/claude-config
  mkdir -p "$(dirname "$(_marker smartwatermelon/claude-config)")"
  printf '%s\n' "$(($(date +%s) - 60))" >"$(_marker smartwatermelon/claude-config)"
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 0 ]]
  [[ "${output}" == *"already filed for PR #7 in this auth window"* ]]
}

@test "known-bad: a stale marker from an earlier authorization files again" {
  _valid_lock smartwatermelon/claude-config
  mkdir -p "$(dirname "$(_marker smartwatermelon/claude-config)")"
  printf '%s\n' "$(($(date +%s) - 7200))" >"$(_marker smartwatermelon/claude-config)"
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 1 ]]
  [[ "${output}" != *"already filed"* ]]
  # The new filing refreshes the marker.
  (($(date +%s) - $(head -1 "$(_marker smartwatermelon/claude-config)") < 60))
}

@test "known-bad: a marker for the same PR number in another repo does not skip filing" {
  _valid_lock smartwatermelon/claude-config
  mkdir -p "$(dirname "$(_marker smartwatermelon/dotfiles)")"
  date +%s >"$(_marker smartwatermelon/dotfiles)"
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "$(_issue_count)" -eq 1 ]]
}

@test "a legacy ISSUES_CREATED=1 in a lock still skips filing" {
  local lock="${HOME}/.claude/merge-locks/smartwatermelon/claude-config/pr-7.lock"
  mkdir -p "$(dirname "${lock}")"
  printf 'TIMESTAMP=%s\nISSUES_CREATED=1\n' "$(date +%s)" >"${lock}"
  _pre_merge smartwatermelon/claude-config twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 0 ]]
  [[ "${output}" == *"already filed for PR #7 in this auth window"* ]]
}

@test "an exempt merge writes the review state dir, never merge-locks" {
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  grep -q $'\tsmartwatermelon/dev-env\t7\ttwistedmelonman\t' "${EXEMPT_LOG}"
  [[ -s "$(_marker smartwatermelon/dev-env)" ]]
  [[ ! -e "${LEGACY_EXEMPT_LOG}" ]]
  # merge-locks holds nothing the merge run wrote.
  [[ -z "$(find "${HOME}/.claude/merge-locks" -type f)" ]]
}

@test "the exempt log dir is created when missing" {
  rm -r "${REVIEW_STATE_DIR}"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE
  [[ "${status}" -eq 0 ]]
  grep -q $'\tsmartwatermelon/dev-env\t7\t' "${EXEMPT_LOG}"
}

@test "known-bad: a recent row in the legacy exempt log still suppresses re-filing" {
  printf '%s\tsmartwatermelon/dev-env\t7\ttwistedmelonman\tx\n' "$(date +%s)" >"${LEGACY_EXEMPT_LOG}"
  local before
  before=$(cat "${LEGACY_EXEMPT_LOG}")
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "${status}" -eq 0 ]]
  [[ "$(_issue_count)" -eq 0 ]]
  [[ "${output}" == *"already filed for smartwatermelon/dev-env#7 in this exempt window"* ]]
  # The legacy log is read, never appended to; the new row goes to the state dir.
  [[ "$(cat "${LEGACY_EXEMPT_LOG}")" == "${before}" ]]
  grep -q $'\tsmartwatermelon/dev-env\t7\t' "${EXEMPT_LOG}"
}

@test "an old row in the legacy exempt log does not suppress filing" {
  printf '%s\tsmartwatermelon/dev-env\t7\ttwistedmelonman\tx\n' "$(($(date +%s) - 7200))" >"${LEGACY_EXEMPT_LOG}"
  _pre_merge smartwatermelon/dev-env twistedmelonman SAFE_TO_MERGE findings
  [[ "$(_issue_count)" -eq 1 ]]
}
