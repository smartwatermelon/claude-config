#!/usr/bin/env bats
# Tests for ~/.local/bin/gh binary wrapper
#
# Verifies the _GH_REVIEW_DONE guard prevents double review when this binary
# wrapper is called from the gh() bash function, which already ran the review.
#
# Root cause of double review on dotfiles PR #4:
#   1. gh() bash function (functions.sh) intercepts "gh pr merge" → runs review
#   2. gh() calls "command gh" which resolves to ~/.local/bin/gh (a bash script)
#   3. That script also intercepts "pr merge" → runs review AGAIN
#
# Fix: gh() sets _GH_REVIEW_DONE=1 before calling "command gh"; this script
# checks it and skips the review when the review has already been done.
#
# Run: bats ~/.claude/tests/test_gh_binary_wrapper.bats

GH_WRAPPER="${HOME}/.local/bin/gh"

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock "real" gh binary — _find_real_gh() in the wrapper will find this
  # (it's not ~/.local/bin/gh, so it passes the realpath check)
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Mock HOME with a review script that records its calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  # review_called is created only if the review script runs.
  # Tests asserting review bypass will check it does NOT exist.
  cat >"${MOCK_HOME}/.claude/hooks/pre-merge-review.sh" <<EOF
#!/usr/bin/env bash
echo "called" >"${MOCK_DIR}/review_called"
exit 0
EOF
  chmod +x "${MOCK_HOME}/.claude/hooks/pre-merge-review.sh"
}

teardown() {
  rm -rf "${MOCK_DIR}"
}

@test "gh pr merge skips review when _GH_REVIEW_DONE=1" {
  # Regression guard for double-review bug:
  # When the gh() bash function already ran the review and then calls "command gh",
  # this binary wrapper must NOT run the review a second time.
  run env HOME="${MOCK_HOME}" _GH_REVIEW_DONE=1 "${GH_WRAPPER}" pr merge 53 --squash

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge calls review when _GH_REVIEW_DONE is unset" {
  # Normal path: binary wrapper called directly (not via gh() function).
  # Review must still run when no guard is set.
  run env HOME="${MOCK_HOME}" "${GH_WRAPPER}" pr merge 53 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status never calls review" {
  # Non-pr-merge commands must never trigger the review, with or without guard.
  run env HOME="${MOCK_HOME}" "${GH_WRAPPER}" status

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}
