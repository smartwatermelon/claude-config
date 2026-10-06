#!/usr/bin/env bats
# Tests that hooks/run-review.sh leaves lockfiles out of a MIXED commit's
# review input and size count (claude-config#689).
#
# Why this exists: the lockfile skip was all-or-nothing. A dependency bump
# stages the manifest with the lockfile it produced (package.json +
# pnpm-lock.yaml), so the skip never fired, the lockfile's lines counted
# against review.skipThreshold, and the commit was blocked as "diff too
# large". A lockfile is exempt from review at any size (#427), so its size
# can only ever block a commit it would add zero findings to.
#
# The mock CLI returns PASS and saves every prompt it is sent, so the tests
# can check what the reviewers actually saw.
#
# Run: bats tests/test_run_review_lockfile_mixed_commit.bats

# Resolve the script under test relative to THIS test file, so a worktree
# tests its own copy (see test_run_review_generated_file_skip_order.bats).
SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  git -C "${TMPDIR_TEST}" init -q
  git -C "${TMPDIR_TEST}" checkout -q -b test-branch
  git -C "${TMPDIR_TEST}" config user.email "test@test.com"
  git -C "${TMPDIR_TEST}" config user.name "Test"
  touch "${TMPDIR_TEST}/init.txt"
  git -C "${TMPDIR_TEST}" add init.txt
  GIT_CONFIG_GLOBAL=/dev/null git -C "${TMPDIR_TEST}" commit -q -m "initial commit message"

  export EXPECTED_LOG="${TMPDIR_TEST}/.git/last-review-result.log"

  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  # Fake HOME with no plugins: only code-reviewer runs, and nothing touches
  # the real home directory.
  FAKE_HOME="${MOCK_DIR}/home"
  export FAKE_HOME
  mkdir -p "${FAKE_HOME}/.claude"

  # Mock claude CLI. The --version preflight must not consume stdin. Every
  # --agent call (a reviewer) saves its stdin, the prompt that carries the
  # diff, to its own file under ${SEEN_DIR} and answers PASS. Calls without
  # --agent, such as the haiku-alias probe, are not reviews and are not saved.
  export SEEN_DIR="${MOCK_DIR}/seen"
  mkdir -p "${SEEN_DIR}"
  cat >"${MOCK_DIR}/claude" <<EOF
#!/usr/bin/env bash
is_agent=false
for a in "\$@"; do
  if [[ "\$a" == "--version" ]]; then
    echo "mock-claude 0.0.1"
    exit 0
  fi
  [[ "\$a" == "--agent" ]] && is_agent=true
done
if [[ "\$is_agent" == true ]]; then
  cat >"\$(mktemp "${SEEN_DIR}/prompt.XXXXXX")"
else
  cat >/dev/null
fi
jq -n '{type:"result",subtype:"success",is_error:false,
        result:"VERDICT: PASS\nNo blocking issues found.",
        structured_output:{verdict:"PASS",blocking:false,findings:[]}}'
EOF
  chmod +x "${MOCK_DIR}/claude"
  export CLAUDE_CLI="${MOCK_DIR}/claude"
}

teardown() {
  rm -rf "${TMPDIR_TEST}" "${MOCK_DIR}"
}

# Write a file of N lines into the temp repo. The text is unique per path,
# so a grep for the path's marker finds only that file's hunks.
_write_file() {
  local path="$1" lines="$2" i
  : >"${TMPDIR_TEST}/${path}"
  for ((i = 0; i < lines; i += 1)); do
    printf '%s line %d\n' "${path}" "${i}" >>"${TMPDIR_TEST}/${path}"
  done
}

_write_manifest() {
  printf '{\n  "name": "demo",\n  "dependencies": { "astro": "^7.0.0" }\n}\n' \
    >"${TMPDIR_TEST}/package.json"
}

# Same launch pattern as the other run-review.sh bats files: run from inside
# the temp repo (the script reads its own cwd's staged index), in a subshell
# so the cd cannot leak, with the developer's global review.* keys masked.
_run_review() {
  local diff
  diff=$(git -C "${TMPDIR_TEST}" diff --cached)
  (
    cd "${TMPDIR_TEST}" || return 1
    printf '%s\n' "${diff}" \
      | HOME="${FAKE_HOME}" REVIEW_LOG="${EXPECTED_LOG}" CLAUDE_CLI="${CLAUDE_CLI}" \
        GIT_CONFIG_GLOBAL=/dev/null bash "${SCRIPT}" "$@"
  )
}

# Fail when PATTERN matches any FILE. A bare `! grep` is not enough here:
# bash's errexit ignores a `!`-negated command, so mid-test it could never
# fail the test. A function that returns 1 does trip errexit.
refute_grep() {
  local pattern="$1"
  shift
  if grep -q -- "${pattern}" "$@"; then
    echo "unexpected match for '${pattern}' in: $*" >&2
    return 1
  fi
}

# How many prompts reached the mock reviewer. Counted with find and compared
# with [ ], rather than returned as a function status, so the result does not
# depend on how the shell treats a failing function on a test's last line.
_prompt_count() {
  find "${SEEN_DIR}" -name 'prompt.*' -type f | wc -l | tr -d ' '
}

@test "manifest + large lockfile is reviewed, not blocked on the lockfile's size" {
  _write_manifest
  _write_file "pnpm-lock.yaml" 4000
  git -C "${TMPDIR_TEST}" add package.json pnpm-lock.yaml

  run _run_review
  [ "$status" -eq 0 ]
  [ "$(_prompt_count)" -gt 0 ]
  refute_grep 'blocked: diff too large' "${EXPECTED_LOG}"
  refute_grep 'skipped: lockfile-only' "${EXPECTED_LOG}"
  grep -q 'excluded: lockfiles (pnpm-lock.yaml)' "${EXPECTED_LOG}"
  # The non-blocking nudge toward a separate lockfile commit.
  [[ "$output" == *"Lockfile excluded from review"* ]]
  [[ "$output" == *"commit a regenerated lockfile on its own"* ]]
}

@test "the diff the reviewer sees has the manifest but no lockfile hunks" {
  _write_manifest
  _write_file "pnpm-lock.yaml" 4000
  git -C "${TMPDIR_TEST}" add package.json pnpm-lock.yaml

  run _run_review
  [ "$status" -eq 0 ]
  [ "$(_prompt_count)" -gt 0 ]
  # Positive control first: the saved prompts do carry the diff.
  grep -q 'astro' "${SEEN_DIR}"/prompt.*
  # No lockfile content and no lockfile diff header in any prompt.
  refute_grep 'pnpm-lock.yaml line' "${SEEN_DIR}"/prompt.*
  refute_grep 'diff --git a/pnpm-lock.yaml' "${SEEN_DIR}"/prompt.*
}

@test "a mixed commit whose remainder lands in the chunked band leaves the lockfile out of the chunks" {
  # Two 600-line files: together above review.maxLines (1000), each under
  # review.chunkSize (800). With the 2000-line lockfile the old total was
  # over skipThreshold (2500) and blocked; without it, chunked review runs.
  _write_file "a.sh" 600
  _write_file "b.sh" 600
  _write_file "yarn.lock" 2000
  git -C "${TMPDIR_TEST}" add a.sh b.sh yarn.lock

  run _run_review
  [ "$status" -eq 0 ]
  grep -q 'chunked review' "${EXPECTED_LOG}"
  refute_grep 'blocked: diff too large' "${EXPECTED_LOG}"
  grep -q 'a.sh line' "${SEEN_DIR}"/prompt.*
  refute_grep 'yarn.lock line' "${SEEN_DIR}"/prompt.*
}

@test "a lockfile-only commit is still skipped as lockfile-only" {
  _write_file "pnpm-lock.yaml" 4000
  git -C "${TMPDIR_TEST}" add pnpm-lock.yaml

  run _run_review
  [ "$status" -eq 0 ]
  [[ "$output" == *"Lockfile-only changes detected"* ]]
  grep -q 'skipped: lockfile-only' "${EXPECTED_LOG}"
  [ "$(_prompt_count)" -eq 0 ]
}

@test "a mixed commit whose non-lockfile part alone exceeds the threshold is still blocked" {
  _write_file "app.sh" 3000
  _write_file "pnpm-lock.yaml" 4000
  git -C "${TMPDIR_TEST}" add app.sh pnpm-lock.yaml

  run _run_review
  [ "$status" -ne 0 ]
  [ "$(_prompt_count)" -eq 0 ]
  grep -q 'blocked: diff too large' "${EXPECTED_LOG}"
  # The measured size is the remainder's, not remainder + lockfile (~7000).
  local measured
  measured=$(sed -n 's/^blocked: diff too large (\([0-9]*\) lines.*/\1/p' "${EXPECTED_LOG}")
  [ "${measured}" -gt 2500 ]
  [ "${measured}" -lt 4000 ]
  # The block message now says a lockfile can go in a commit of its own.
  [[ "$output" == *"A regenerated lockfile"* ]]
}

@test "full-diff mode does not strip lockfiles from the piped diff" {
  # The exclusion is commit-mode only (#131): full-diff reviews the piped
  # branch diff, not the staged index, so it must see what it was given.
  _write_manifest
  _write_file "pnpm-lock.yaml" 50
  git -C "${TMPDIR_TEST}" add package.json pnpm-lock.yaml

  run _run_review --mode=full-diff --no-file
  refute_grep 'excluded: lockfiles' "${EXPECTED_LOG}"
  [[ "$output" != *"Lockfile excluded from review"* ]]
}
