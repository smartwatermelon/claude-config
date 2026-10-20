#!/usr/bin/env bash
# Prints skip=true only when a PR changes scripts/known-runtime.txt alone (#732). Any error prints skip=false.
set -uo pipefail
unset CDPATH

SKIP_ONLY_FILE="scripts/known-runtime.txt"

# Env: GITHUB_REPOSITORY, PR_BASE_SHA, PR_HEAD_SHA, GH_TOKEN. CI appends stdout to $GITHUB_OUTPUT.

run_all() {
  echo "ci-tests-scope: $1; running the full suite" >&2
  echo "skip=false"
  exit 0
}

repo="${GITHUB_REPOSITORY:-}"
base="${PR_BASE_SHA:-}"
head="${PR_HEAD_SHA:-}"
[[ -n "${repo}" && -n "${base}" && -n "${head}" ]] || run_all "GITHUB_REPOSITORY, PR_BASE_SHA or PR_HEAD_SHA is unset"

# Three-dot compare at the event SHAs judges the commit under test. A rename lists both its old and new path.
if ! files="$(gh api --paginate "repos/${repo}/compare/${base}...${head}" \
  --jq '.files[] | .filename, (.previous_filename // empty)')"; then
  run_all "cannot read the changed-file list"
fi

[[ -n "${files}" ]] || run_all "the changed-file list is empty"

while IFS= read -r path; do
  [[ "${path}" == "${SKIP_ONLY_FILE}" ]] || run_all "${path} changed"
done <<<"${files}"

echo "ci-tests-scope: only ${SKIP_ONLY_FILE} changed; skipping the full suite" >&2
echo "skip=true"
