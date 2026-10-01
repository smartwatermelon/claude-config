#!/usr/bin/env bash
# Runs every test suite in this repo: tests/*.bats, scripts/tests/test-*.sh,
# hooks/tests/*.sh, and the root test-pre-merge-review.sh. CI calls it as a
# required check; run it by hand for a local full run.
#
# Before this existed nothing ran these tests: CI ran linters only and there
# was no .project-hooks/pre-push, so two bats cases sat red on main for four
# days (twistedmelonman/claude-config#638).
#
# Usage: scripts/run-tests.sh [--fail-fast]
#   --fail-fast  stop at the first failing suite (for local runs; CI runs
#                everything so one push reports every failure)
#
# RUN_TESTS_ROOT overrides the repo root. It exists for this runner's own
# tests, which point it at a scratch tree of fake suites.
#
# Exit: 0 when every suite passed, 1 when any failed, 2 on a usage or
# environment error (no suites found, bats missing, bash too old).
set -uo pipefail
unset CDPATH

fail_fast=0
for arg in "$@"; do
  case "${arg}" in
    --fail-fast) fail_fast=1 ;;
    -h | --help)
      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "run-tests.sh: unknown argument: ${arg}" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="${RUN_TESTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# git exports GIT_DIR (and friends) into hooks. Inherited by a suite, it points
# every `git init` and `git commit` meant for a temp repo at THIS repo instead:
# the first pre-push run set core.bare=true in the shared .git/config and
# committed a fixture onto the branch being pushed.
if ! git_vars="$(git rev-parse --local-env-vars)"; then
  echo "run-tests.sh: cannot list git's repo-local variables to clear them" >&2
  exit 2
fi
while IFS= read -r git_var; do
  unset "${git_var}"
done <<<"${git_vars}"

# macOS ships bash 3.2, and the shell suites need 4.4+. "${BASH}", not a bare
# `bash`: a git hook's PATH can resolve `bash` to 3.2 even when this script
# itself is running under 5.
runner_bash="${BASH}"
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  runner_bash=""
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "${candidate}" ]]; then
      runner_bash="${candidate}"
      break
    fi
  done
  if [[ -z "${runner_bash}" ]]; then
    echo "run-tests.sh: bash ${BASH_VERSION} is too old and no bash 4.4+ was found" >&2
    exit 2
  fi
fi

shopt -s nullglob
bats_suites=("${REPO_ROOT}"/tests/*.bats)
sh_suites=("${REPO_ROOT}"/scripts/tests/test-*.sh "${REPO_ROOT}"/hooks/tests/*.sh)
if [[ -f "${REPO_ROOT}/test-pre-merge-review.sh" ]]; then
  sh_suites+=("${REPO_ROOT}/test-pre-merge-review.sh")
fi
shopt -u nullglob

if ((${#bats_suites[@]} + ${#sh_suites[@]} == 0)); then
  echo "run-tests.sh: no test suites found under ${REPO_ROOT}" >&2
  exit 2
fi
if ((${#bats_suites[@]} > 0)) && ! command -v bats >/dev/null 2>&1; then
  echo "run-tests.sh: bats is not installed (brew install bats-core)" >&2
  exit 2
fi

# gh-wrapper.sh lives in dotfiles, not here. Resolve it from the real HOME now,
# before each suite gets a sandbox HOME below; CI sets GH_WRAPPER_LIB to a
# dotfiles checkout instead.
if [[ -z "${GH_WRAPPER_LIB:-}" && -f "${HOME}/.config/bash/gh-wrapper.sh" ]]; then
  export GH_WRAPPER_LIB="${HOME}/.config/bash/gh-wrapper.sh"
fi

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "${LOG_DIR}"' EXIT
suite_count=0

passed=0
failed=()

# Runs one suite with its output captured, and prints the output only when it
# fails, so a clean run is one line per suite.
#
# Each suite gets its own empty HOME and XDG_CONFIG_HOME. Several suites write
# ${HOME}/.claude/blocked-commands.log or last-review-result.log through the
# code they exercise, and some read the installed hooks under ~/.claude, which
# symlink into the main checkout rather than the branch under test. A sandbox
# keeps a local run from touching the live install and makes it see what a CI
# runner sees. A fresh one per suite keeps one suite's leftovers out of the next.
run_suite() {
  local name="$1"
  shift
  local log="${LOG_DIR}/${name//\//_}.log"
  suite_count=$((suite_count + 1))
  local suite_home="${LOG_DIR}/home-${suite_count}"
  mkdir -p "${suite_home}/.config"
  if HOME="${suite_home}" XDG_CONFIG_HOME="${suite_home}/.config" \
    "$@" >"${log}" 2>&1; then
    printf 'PASS  %s\n' "${name}"
    passed=$((passed + 1))
    return 0
  fi
  printf 'FAIL  %s\n' "${name}"
  sed 's/^/      /' "${log}"
  failed+=("${name}")
  return 1
}

for suite in "${bats_suites[@]}"; do
  run_suite "${suite#"${REPO_ROOT}/"}" bats "${suite}" || { ((fail_fast)) && break; }
done
# Skip the shell suites only when --fail-fast already saw a bats failure.
if [[ "${fail_fast}" -eq 0 || "${#failed[@]}" -eq 0 ]]; then
  for suite in "${sh_suites[@]}"; do
    run_suite "${suite#"${REPO_ROOT}/"}" "${runner_bash}" "${suite}" || { ((fail_fast)) && break; }
  done
fi

echo ""
if ((${#failed[@]} == 0)); then
  echo "All ${passed} suites passed."
  exit 0
fi
echo "${#failed[@]} suite(s) failed, ${passed} passed:"
printf '  %s\n' "${failed[@]}"
if ((fail_fast)); then
  echo "(--fail-fast: stopped at the first failure; later suites did not run)"
fi
exit 1
