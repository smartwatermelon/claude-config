#!/usr/bin/env bash
# Stub for gh api repos/<o>/<n> (GATE_GH): GATE_TEST_FORKS answer true, GATE_TEST_GH_FAIL fail, others false.

# GATE_TEST_GH_LOG, when set, gets one line per repo looked up.
set -euo pipefail
[[ "${1:-}" == "api" && "${2:-}" == repos/*/* ]] || exit 1
repo="${2#repos/}"
repo="${repo,,}"
[[ -z "${GATE_TEST_GH_LOG:-}" ]] || printf '%s\n' "${repo}" >>"${GATE_TEST_GH_LOG}"
for r in ${GATE_TEST_GH_FAIL:-}; do
  [[ "${r,,}" != "${repo}" ]] || exit 1
done
for r in ${GATE_TEST_FORKS:-}; do
  if [[ "${r,,}" == "${repo}" ]]; then
    printf 'true\n'
    exit 0
  fi
done
printf 'false\n'
