#!/usr/bin/env bats
# Tests for --repo / -R passthrough in pre-merge-review.sh
#
# Background: pre-merge-review.sh resolves the target repo via `gh repo view`
# (CWD-dependent) and then issues `gh pr view N` / `gh pr diff N` calls that
# also fall back to CWD when --repo is absent. When the caller invokes
# `gh -R owner/repo pr merge N` (or `--repo owner/repo`) from outside the
# target repo's clone, the CWD-based resolution picks up the wrong repo and
# the GraphQL query later fails with "Could not resolve to a PullRequest with
# the number of N".
#
# Fix: parse --repo (and -R, --repo=, -R=) from the original args; when
# provided, set REPO_OWNER/REPO_NAME directly from the flag value (skipping
# the CWD-dependent `gh repo view` calls) and propagate --repo to all
# `gh pr view` / `gh pr diff` invocations. Also replaces the brittle
# `shift 2` with a global-flag-aware positional counter.
#
# Run: bats ~/.claude/tests/test_pre_merge_repo_flag.bats

SCRIPT="${HOME}/.claude/hooks/pre-merge-review.sh"
VALID_JSON='{"number":123,"title":"test PR","reviewDecision":"APPROVED","reviews":[],"comments":[],"state":"OPEN","statusCheckRollup":[{"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}'

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock gh that records every invocation to ${MOCK_DIR}/gh_calls.log,
  # one line per call, args separated by '|'. Returns canned responses
  # so the script reaches the GraphQL block (and beyond) without falling
  # over on missing data.
  cat >"${MOCK_DIR}/gh" <<EOF
#!/usr/bin/env bash
# Record this invocation: subcommand path + flags
printf '%s\n' "\$(IFS='|'; echo "\$*")" >>"${MOCK_DIR}/gh_calls.log"

# pr view --json ... → return PR JSON
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  for arg in "\$@"; do
    if [[ "\${arg}" == "--json" ]]; then
      echo '${VALID_JSON}'
      exit 0
    fi
  done
  # pr view --comments → return empty
  echo ""
  exit 0
fi

# pr diff → empty
if [[ "\$1" == "pr" && "\$2" == "diff" ]]; then
  echo ""
  exit 0
fi

# repo view → return owner/name (the WRONG one — proves we used --repo
# when test asserts otherwise)
if [[ "\$1" == "repo" && "\$2" == "view" ]]; then
  for arg in "\$@"; do
    if [[ "\${arg}" == ".owner.login" ]]; then
      echo "wrong-owner"
      exit 0
    fi
    if [[ "\${arg}" == ".name" ]]; then
      echo "wrong-name"
      exit 0
    fi
  done
  exit 0
fi

# api → empty array (no inline comments)
if [[ "\$1" == "api" ]]; then
  if [[ "\$2" == "graphql" ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
    exit 0
  fi
  echo "[]"
  exit 0
fi

exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Mock claude CLI — must exist and be executable for preflight to pass.
  # Returns a SAFE_TO_MERGE verdict so the script reaches normal completion.
  cat >"${MOCK_DIR}/claude" <<'CLAUDE_EOF'
#!/usr/bin/env bash
cat >/dev/null # consume stdin prompt
echo "VERDICT: SAFE_TO_MERGE"
echo "All good."
exit 0
CLAUDE_EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"

  # Mock merge-lock.sh — always authorized so we test only the parsing path.
  cat >"${MOCK_DIR}/merge-lock.sh" <<'LOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "check" ]]; then
  exit 0
fi
LOCK_EOF
  chmod +x "${MOCK_DIR}/merge-lock.sh"
  export MOCK_LOCK="${MOCK_DIR}/merge-lock.sh"

  # Mock create_nonblocking_issues so the lib doesn't try to file issues
  # or read state we haven't mocked. The script sources lib-review-issues.sh
  # which provides this; we don't need to override unless it misbehaves.
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

# Run the script with a custom argv. Sets up a clean mock HOME with the
# merge-lock and lib symlinked, so the script's `source` of lib-review-issues.sh
# resolves correctly relative to the real script.
_run_script() {
  env HOME="${MOCK_DIR}/home" PATH="${MOCK_DIR}:${PATH}" \
    bash -c "
      export HOME='${MOCK_DIR}/home'
      export CLAUDE_CLI='${CLAUDE_CLI}'
      mkdir -p \"\${HOME}/.claude/hooks\"
      cp '${MOCK_LOCK}' \"\${HOME}/.claude/hooks/merge-lock.sh\"
      chmod +x \"\${HOME}/.claude/hooks/merge-lock.sh\"
      '${SCRIPT}' $*
    " 2>&1
}

# Helper: count `gh repo view` invocations recorded by the mock.
_repo_view_count() {
  if [[ ! -f "${MOCK_DIR}/gh_calls.log" ]]; then
    echo 0
    return
  fi
  grep -c '^repo|view' "${MOCK_DIR}/gh_calls.log" || true
}

# Helper: assert that some `gh pr view N` call had `--repo OWNER/NAME`.
_pr_view_has_repo() {
  local owner_repo="$1"
  grep -E "^pr\|view\|" "${MOCK_DIR}/gh_calls.log" \
    | grep -qE "(^|\|)--repo\|${owner_repo}(\||$)"
}

# Helper: assert that some `gh pr diff N` call had `--repo OWNER/NAME`.
_pr_diff_has_repo() {
  local owner_repo="$1"
  grep -E "^pr\|diff\|" "${MOCK_DIR}/gh_calls.log" \
    | grep -qE "(^|\|)--repo\|${owner_repo}(\||$)"
}

# Helper: assert that some `gh pr view N` was invoked with the given PR number.
_pr_view_has_number() {
  local pr_num="$1"
  grep -E "^pr\|view\|" "${MOCK_DIR}/gh_calls.log" \
    | grep -qE "(^|\|)${pr_num}(\||$)"
}

# ── -R short form ────────────────────────────────────────────────────────────

@test "gh -R owner/repo pr merge 123 --squash --delete-branch: --repo propagated; gh repo view skipped" {
  run _run_script -R owner/repo pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  [[ "$(_repo_view_count)" -eq 0 ]]
  _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── --repo long form ─────────────────────────────────────────────────────────

@test "gh --repo owner/repo pr merge 123 --squash --delete-branch: --repo propagated" {
  run _run_script --repo owner/repo pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  [[ "$(_repo_view_count)" -eq 0 ]]
  _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── --repo=value form ────────────────────────────────────────────────────────

@test "gh --repo=owner/repo pr merge 123 --squash --delete-branch: --repo propagated" {
  run _run_script --repo=owner/repo pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  [[ "$(_repo_view_count)" -eq 0 ]]
  _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── -R=value form ────────────────────────────────────────────────────────────

@test "gh -R=owner/repo pr merge 123 --squash --delete-branch: --repo propagated" {
  run _run_script -R=owner/repo pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  [[ "$(_repo_view_count)" -eq 0 ]]
  _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── No --repo: legacy CWD-based behavior preserved ───────────────────────────

@test "gh pr merge 123 --squash --delete-branch (no --repo): gh repo view IS called; pr view has NO --repo flag" {
  run _run_script pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  # Without --repo, the script falls back to gh repo view (CWD-based) — the
  # exact pre-fix behavior, preserved by the new parser.
  [[ "$(_repo_view_count)" -ge 1 ]]
  # And no --repo flag is added to pr view / pr diff.
  ! _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── Multiple global flags: only --repo captured ──────────────────────────────

@test "gh -R owner/repo --hostname example.com pr merge 123: only --repo captured; --hostname value not consumed as PR" {
  # --hostname takes a separate value (example.com) which the parser must skip.
  # If the parser mishandles it, "example.com" or some other token could be
  # mistaken for the PR number — but we passed 123 explicitly so this asserts
  # the parser still finds it.
  run _run_script -R owner/repo --hostname example.com pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  [[ "$(_repo_view_count)" -eq 0 ]]
  _pr_view_has_repo "owner/repo"
  _pr_view_has_number "123"
}

# ── --repo with global flag AFTER subcommand ─────────────────────────────────

@test "gh pr merge 123 --squash (no --repo, no extra flags): PR_NUMBER still extracted" {
  # Sanity: regression check that the new positional-count logic doesn't
  # accidentally treat "merge" or "pr" as PR_NUMBER (neither is numeric, so
  # this would only matter if the count check were buggy).
  run _run_script pr merge 123 --squash --delete-branch

  [[ "${status}" -eq 0 ]]
  _pr_view_has_number "123"
}
