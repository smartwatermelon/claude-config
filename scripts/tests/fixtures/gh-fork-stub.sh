#!/usr/bin/env bash
# Stub for gh api repos/<o>/<n> (GATE_GH). It answers the --jq field asked for.

# .fork (the default): GATE_TEST_FORKS are true. .private: GATE_TEST_PRIVATE are true.

# Other repos are false. GATE_TEST_GH_FAIL repos, and any other field, fail.

# GATE_TEST_GH_LOG, when set, gets one line per repo looked up.
set -euo pipefail
[[ "${1:-}" == "api" && "${2:-}" == repos/*/* ]] || exit 1
repo="${2#repos/}"
repo="${repo,,}"
shift 2
field=".fork"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq)
      [[ $# -ge 2 ]] || exit 1
      field="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -z "${GATE_TEST_GH_LOG:-}" ]] || printf '%s\n' "${repo}" >>"${GATE_TEST_GH_LOG}"
for r in ${GATE_TEST_GH_FAIL:-}; do
  [[ "${r,,}" != "${repo}" ]] || exit 1
done
case "${field}" in
  .fork) list="${GATE_TEST_FORKS:-}" ;;
  .private) list="${GATE_TEST_PRIVATE:-}" ;;
  *) exit 1 ;;
esac
for r in ${list}; do
  if [[ "${r,,}" == "${repo}" ]]; then
    printf 'true\n'
    exit 0
  fi
done
printf 'false\n'
