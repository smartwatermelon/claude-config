#!/usr/bin/env bash
# Every Workflow script under skills/ must parse; wrapped in an async function, as top-level return needs.

set -uo pipefail
unset CDPATH

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node not found; it is needed to parse the Workflow scripts" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

fail=0
found=0
while IFS= read -r script; do
  found=$((found + 1))
  wrapped="${WORK}/wrapped.mjs"
  {
    echo '(async () => {'
    sed 's/^export const meta/const meta/' "${script}"
    echo '})'
  } >"${wrapped}"
  rel="${script#"${REPO_ROOT}"/}"
  if err="$(node --check "${wrapped}" 2>&1)"; then
    echo "  PASS: ${rel}"
  else
    echo "  FAIL: ${rel}" >&2
    printf '%s\n' "${err}" | grep -m1 'SyntaxError' >&2
    fail=1
  fi
done < <(grep -rl --include='*.js' '^export const meta' "${REPO_ROOT}/skills" || true)

if [[ "${found}" -eq 0 ]]; then
  echo "FAIL: no Workflow scripts found under skills/" >&2
  exit 1
fi

exit "${fail}"
