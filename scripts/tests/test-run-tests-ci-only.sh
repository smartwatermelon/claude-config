#!/usr/bin/env bash
# Tests for scripts/run-tests.sh: outside CI it refuses before running a suite.
set -uo pipefail

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-tests.sh"
FAKE="$(mktemp -d)"
trap 'rm -rf "${FAKE}"' EXIT
mkdir -p "${FAKE}/scripts/tests"
printf 'echo marker-ran; exit 1\n' >"${FAKE}/scripts/tests/test-a.sh"
fail=0

out="$(GITHUB_ACTIONS='' RUN_TESTS_ROOT="${FAKE}" bash "${RUNNER}" 2>&1)"
rc=$?
if [[ "${rc}" == 3 && "${out}" == *"CI only"* && "${out}" != *marker-ran* ]]; then
  echo "PASS: outside CI the runner refuses with exit 3"
else
  echo "FAIL: outside CI: rc=${rc} out=${out}"
  fail=1
fi

out="$(GITHUB_ACTIONS=true RUN_TESTS_ROOT="${FAKE}" bash "${RUNNER}" 2>&1)"
if [[ "${out}" == *marker-ran* ]]; then
  echo "PASS: in CI the runner runs suites"
else
  echo "FAIL: in CI the runner did not run the suite: ${out}"
  fail=1
fi

exit "${fail}"
