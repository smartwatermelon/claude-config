#!/usr/bin/env bash
# Tests for scripts/run-tests.sh: outside CI it refuses before running a suite,
# unless RUN_FULL_SUITE=1 (the human override).
set -uo pipefail

RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/run-tests.sh"
FAKE="$(mktemp -d)"
trap 'rm -rf "${FAKE}"' EXIT
mkdir -p "${FAKE}/scripts/tests"
printf 'echo marker-ran; exit 1\n' >"${FAKE}/scripts/tests/test-a.sh"
fail=0

out="$(GITHUB_ACTIONS='' RUN_FULL_SUITE='' RUN_TESTS_ROOT="${FAKE}" bash "${RUNNER}" 2>&1)"
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

out="$(GITHUB_ACTIONS='' RUN_FULL_SUITE=1 RUN_TESTS_ROOT="${FAKE}" bash "${RUNNER}" 2>&1)"
if [[ "${out}" == *marker-ran* ]]; then
  echo "PASS: RUN_FULL_SUITE=1 runs suites outside CI"
else
  echo "FAIL: RUN_FULL_SUITE=1 did not run the suite: ${out}"
  fail=1
fi

out="$(GITHUB_ACTIONS='' RUN_FULL_SUITE=yes RUN_TESTS_ROOT="${FAKE}" bash "${RUNNER}" 2>&1)"
rc=$?
if [[ "${rc}" == 3 && "${out}" != *marker-ran* ]]; then
  echo "PASS: only RUN_FULL_SUITE=1 overrides, not other values"
else
  echo "FAIL: RUN_FULL_SUITE=yes: rc=${rc} out=${out}"
  fail=1
fi

exit "${fail}"
