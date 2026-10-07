#!/usr/bin/env bats
# Guards that test suites resolve the scripts under test from the checkout
# they live in, not from the deployed ~/.claude tree.
#
# Background: several suites used to set SCRIPT="${HOME}/.claude/hooks/...".
# install.sh symlinks ~/.claude/hooks/* back to the main checkout, so an agent
# working in a git worktree ran those grep-based assertions against the
# unmodified main copy. That fails in both directions: new tests for a
# worktree edit fail no matter how correct the edit is, and — worse — a suite
# reports green against main while the worktree change is actually broken.
# This was demonstrated by flipping TIMEOUT_CEILING_SECONDS to 901 in a
# worktree and watching all 22 timeout tests still pass.
#
# Fix: address scripts as "${BATS_TEST_DIRNAME}/../<dir>/<script>". Test files
# are never deployed — install.sh excludes tests/* and *.bats from the symlink
# tree — so BATS_TEST_DIRNAME/.. is always the repo root of whichever checkout
# is being exercised. No ~/.claude fallback is warranted: it could never be
# reached, and would only mask a genuinely missing script.
#
# Run: bats ~/.claude/tests/test_suite_paths_worktree_safe.bats

bats_require_minimum_version 1.5.0

TESTS_DIR="${BATS_TEST_DIRNAME}"
REPO_ROOT="${BATS_TEST_DIRNAME}/.."

@test "no suite resolves the script under test from the deployed ~/.claude tree" {
  # Matches assignments and direct invocations pointing into ~/.claude/hooks
  # or ~/.claude/scripts. Sandboxed fake deploy trees (MOCK_HOME, or a HOME
  # reassigned inside the test) are deliberately excluded: those construct
  # their own tree rather than reading the developer's real one.
  # Anchored at line start so this file's own explanatory prose, which quotes
  # the retired pattern, is not mistaken for a live assignment.
  run grep -rnE '^(SCRIPT|HOOK)="\$\{HOME\}/\.claude/' "${TESTS_DIR}"
  [[ "${status}" -ne 0 ]]

  run grep -rnE 'bash "\$\{HOME\}/\.claude/(hooks|scripts)/' "${TESTS_DIR}"
  [[ "${status}" -ne 0 ]]
}

@test "every BATS_TEST_DIRNAME-relative script reference resolves to a real file" {
  # A path that does not resolve means a suite is silently asserting against
  # nothing, which greps would report as a pass-by-absence.
  local ref path missing=0
  while IFS= read -r ref; do
    [[ -z "${ref}" ]] && continue
    path="${REPO_ROOT}/${ref}"
    if [[ ! -f "${path}" ]]; then
      echo "unresolvable script reference: ${ref}"
      ((missing += 1))
    fi
  done < <(grep -rhoE '\$\{BATS_TEST_DIRNAME\}/\.\./[A-Za-z0-9_./-]+\.sh' "${TESTS_DIR}" \
    | sed 's|\${BATS_TEST_DIRNAME}/\.\./||' | sort -u)

  [[ "${missing}" -eq 0 ]]
}

@test "install.sh excludes tests from the deployed tree, so no ~/.claude fallback is needed" {
  # This is the load-bearing premise of the fix above. If tests ever start
  # being deployed, BATS_TEST_DIRNAME/.. would no longer be a repo root and
  # this guard should fail loudly rather than let the suites drift.
  grep -qE '^\s*tests/\*\) return 0 ;;' "${REPO_ROOT}/install.sh"
  grep -qE '^\s*\*\.bats\) return 0 ;;' "${REPO_ROOT}/install.sh"
}
