#!/usr/bin/env bats
# Tests for gh() wrapper function in ~/.config/bash/functions.sh
#
# Verifies that help flags bypass the pre-merge review script entirely,
# so `gh pr merge --help` just shows help instead of triggering a 120s
# Claude CLI analysis.
#
# Bug: gh() wrapper matches ALL `gh pr merge ...` invocations, including
#   `gh pr merge --help` and `gh pr merge -h`. This runs pre-merge-review.sh
#   for a help request, which takes ~120 seconds and times out silently.
#
# Run: bats ~/.claude/tests/test_gh_wrapper.bats

FUNCTIONS_SH="${HOME}/.config/bash/functions.sh"

setup() {
  MOCK_DIR="$(mktemp -d)"
  export MOCK_DIR
  export PATH="${MOCK_DIR}:${PATH}"

  # Mock gh binary that just exits 0 (bypasses real gh calls)
  cat >"${MOCK_DIR}/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${MOCK_DIR}/gh"

  # Build mock HOME structure with a review script that records its calls
  MOCK_HOME="${MOCK_DIR}/home"
  export MOCK_HOME
  mkdir -p "${MOCK_HOME}/.claude/hooks"

  # review_called is created only if the review script runs.
  # Tests that expect review bypass will assert it does NOT exist.
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

# Load gh() from functions.sh into the current shell with MOCK_HOME active.
# Uses eval so the function's ${HOME} references resolve to MOCK_HOME at
# call time (HOME is set before each direct gh invocation in tests below).
_load_gh_fn() {
  export HOME="${MOCK_HOME}"
  local func_def
  func_def=$(sed -n '/^gh()/,/^export -f gh$/p' "${FUNCTIONS_SH}")
  eval "${func_def}"
}

@test "gh pr merge --help bypasses review script" {
  # Bug reproduction: --help currently triggers pre-merge-review.sh.
  # After fix: gh pr merge --help passes straight to command gh, no review.
  _load_gh_fn

  gh pr merge --help

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge -h bypasses review script" {
  # Same bug with the short -h flag.
  _load_gh_fn

  gh pr merge -h

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}

@test "gh pr merge 123 --squash calls review script" {
  # Regression: real merge operations must still trigger the review.
  _load_gh_fn

  gh pr merge 123 --squash

  [[ -f "${MOCK_DIR}/review_called" ]]
}

@test "gh status passes through without calling review script" {
  # Non-pr-merge commands must never trigger the review.
  _load_gh_fn

  gh status

  [[ ! -f "${MOCK_DIR}/review_called" ]]
}
