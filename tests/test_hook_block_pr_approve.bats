#!/usr/bin/env bats
# Tests for the PreToolUse hook that keeps PR approval human-only.
# Run: bats tests/test_hook_block_pr_approve.bats
#
# Andrew's approving review is the merge lock under the "review" policy
# outcome, so an agent-posted approval would be a forged lock.

HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-block-pr-approve.sh"

setup() {
  TMP_HOME="$(mktemp -d)"
  readonly TMP_HOME
  export HOME="${TMP_HOME}"
  mkdir -p "${HOME}/.claude"
}

teardown() {
  rm -rf "${TMP_HOME}"
}

# Feed a command to the hook the way the harness does. Exit 2 means blocked.
run_hook() {
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" |
    bash "${HOOK}"
}

# --- blocked: gh pr review ---------------------------------------------------

@test "blocks gh pr review --approve" {
  run run_hook 'gh pr review 145 --approve'
  [ "${status}" -eq 2 ]
}

@test "blocks gh pr review -a with a repo flag" {
  run run_hook 'gh pr review 145 -R smartwatermelon/claude-wrapper -a'
  [ "${status}" -eq 2 ]
}

@test "blocks a short-flag cluster holding a" {
  run run_hook 'gh pr review 145 -ab "lgtm"'
  [ "${status}" -eq 2 ]
}

@test "blocks command gh pr review --approve after a cd" {
  run run_hook 'cd /x && command gh pr review --approve 145'
  [ "${status}" -eq 2 ]
}

@test "the block message names the merge, not a way around" {
  run run_hook 'gh pr review 145 --approve'
  [[ "${output}" == *"approving a pull request is a human-only action"* ]]
  [[ "${output}" == *"gh pr merge <N> --squash --delete-branch"* ]]
}

@test "a block is logged" {
  run run_hook 'gh pr review 145 --approve'
  grep -q 'BLOCKED PR APPROVE: gh pr review 145 --approve' "${HOME}/.claude/blocked-commands.log"
}

# --- blocked: REST -----------------------------------------------------------

@test "blocks gh api POST reviews with event=APPROVE" {
  run run_hook 'gh api repos/o/r/pulls/7/reviews -f event=APPROVE'
  [ "${status}" -eq 2 ]
}

@test "blocks a reviews write whose event comes from a file" {
  run run_hook 'gh api repos/o/r/pulls/7/reviews --input body.json'
  [ "${status}" -eq 2 ]
}

@test "blocks submitting a pending review" {
  run run_hook 'gh api -X POST repos/o/r/pulls/7/reviews/99/events -f event=approve'
  [ "${status}" -eq 2 ]
}

@test "blocks a reviews write with -F and no APPROVE word" {
  run run_hook 'gh api repos/o/r/pulls/7/reviews -F event=@ev.txt'
  [ "${status}" -eq 2 ]
}

@test "blocks curl to the reviews endpoint" {
  run run_hook 'curl -s -H "Authorization: token t0k" -d @b.json https://api.github.com/repos/o/r/pulls/7/reviews'
  [ "${status}" -eq 2 ]
}

# --- pending reviews ----------------------------------------------------------

# Feed a command with a cwd, the way the harness does for a relative --input path.
run_hook_cwd() {
  printf '{"cwd":%s,"tool_input":{"command":%s}}' \
    "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" |
    bash "${HOOK}"
}

@test "allows a pending review from a JSON file with no event" {
  printf '{"commit_id":"abc","body":"","comments":[{"path":"a","line":1,"body":"x"}]}' >"${TMP_HOME}/r.json"
  run run_hook "gh api --method POST repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json --jq .html_url"
  [ "${status}" -eq 0 ]
}

@test "allows a pending review through the real gh binary" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "/opt/homebrew/bin/gh api -X POST repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 0 ]
}

@test "known-bad: a relative path blocks, even with a cwd" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook_cwd "${TMP_HOME}" "gh api -X POST repos/o/r/pulls/7/reviews --input r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a second JSON document with an event blocks" {
  printf '{"body":"x"}\n{"event":"COMMENT"}\n' >"${TMP_HOME}/r.json"
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: glob, quote, backslash or tilde in the command blocks" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  for p in "${TMP_HOME}/r?json" "${TMP_HOME}/r*" "\"${TMP_HOME}/r.json\"" "${TMP_HOME}/r\\.json" "${TMP_HOME}/r[.]json"; do
    run run_hook "gh api repos/o/r/pulls/7/reviews --input ${p}"
    [ "${status}" -eq 2 ]
  done
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ~/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a gh at another path blocks" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "/tmp/x/gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a review file with event APPROVE still blocks" {
  printf '{"event":"APPROVE","body":""}' >"${TMP_HOME}/r.json"
  run run_hook "gh api --method POST repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a review file with any event blocks" {
  printf '{"event":"COMMENT","body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a pending review file chained to another command blocks" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json; echo done"
  [ "${status}" -eq 2 ]
  run run_hook "printf '{}' >${TMP_HOME}/r.json && gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a pending review file with an extra field blocks" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json -f event=APPROVE"
  [ "${status}" -eq 2 ]
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json -F event=COMMENT"
  [ "${status}" -eq 2 ]
}

@test "known-bad: stdin, a variable path, or a non-object file blocks" {
  run run_hook 'gh api repos/o/r/pulls/7/reviews --input -'
  [ "${status}" -eq 2 ]
  run run_hook "gh api repos/o/r/pulls/7/reviews --input \"\${F}\""
  [ "${status}" -eq 2 ]
  printf '[]' >"${TMP_HOME}/r.json"
  run run_hook "gh api repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

@test "known-bad: a pending review file sent to a review's own path blocks" {
  printf '{"body":"x"}' >"${TMP_HOME}/r.json"
  run run_hook "gh api -X POST repos/o/r/pulls/7/reviews/99/events --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
  run run_hook "gh api -X PUT repos/o/r/pulls/7/reviews --input ${TMP_HOME}/r.json"
  [ "${status}" -eq 2 ]
}

# --- blocked: GraphQL --------------------------------------------------------

@test "blocks addPullRequestReview" {
  run run_hook 'gh api graphql -f query="mutation { addPullRequestReview(input:{pullRequestId:\"X\", event:APPROVE}) { clientMutationId } }"'
  [ "${status}" -eq 2 ]
}

@test "blocks submitPullRequestReview" {
  run run_hook 'gh api graphql -f query="mutation { submitPullRequestReview(input:{pullRequestReviewId:\"X\", event:APPROVE}) { clientMutationId } }"'
  [ "${status}" -eq 2 ]
}

@test "blocks a GraphQL query read from a file" {
  run run_hook 'gh api graphql -F query=@q.graphql'
  [ "${status}" -eq 2 ]
}

# --- allowed -----------------------------------------------------------------

@test "allows gh pr review --comment" {
  run run_hook 'gh pr review 145 --comment -b "see the note"'
  [ "${status}" -eq 0 ]
}

@test "allows gh pr review --request-changes" {
  run run_hook 'gh pr review 145 --request-changes --body "fix"'
  [ "${status}" -eq 0 ]
}

@test "allows reading reviews" {
  run run_hook "gh api --paginate repos/o/r/pulls/7/reviews?per_page=100 --jq '.[].state'"
  [ "${status}" -eq 0 ]
}

@test "allows reading reviews with -X GET" {
  run run_hook 'gh api -X GET repos/o/r/pulls/7/reviews'
  [ "${status}" -eq 0 ]
  run run_hook 'gh api --method=GET repos/o/r/pulls/7/reviews'
  [ "${status}" -eq 0 ]
}

@test "known-bad: -X GET does not hide a field write" {
  run run_hook 'gh api -X GET repos/o/r/pulls/7/reviews -f body=x'
  [ "${status}" -eq 2 ]
}

@test "known-bad: -X PUT on a review still blocks" {
  run run_hook 'gh api -X PUT repos/o/r/pulls/7/reviews/99'
  [ "${status}" -eq 2 ]
}

@test "allows gh pr view and gh pr merge" {
  run run_hook 'gh pr view 145 --json reviewDecision && gh pr merge 145 --squash --delete-branch'
  [ "${status}" -eq 0 ]
}

@test "allows an inline GraphQL read" {
  run run_hook 'gh api graphql -f query="{ repository(owner:\"o\", name:\"r\") { pullRequest(number:7) { reviewDecision } } }"'
  [ "${status}" -eq 0 ]
}

@test "allows addPullRequestReviewThread-free text that mentions approve" {
  run run_hook 'git commit -m "docs: say who can approve"'
  [ "${status}" -eq 0 ]
}

@test "known-bad: unparseable hook input blocks, it does not fail open" {
  run bash -c 'printf "not json" | bash "$1"' _ "${HOOK}"
  [ "${status}" -eq 2 ]
}

@test "allows an empty command" {
  run run_hook ''
  [ "${status}" -eq 0 ]
}
