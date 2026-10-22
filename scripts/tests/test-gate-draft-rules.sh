#!/usr/bin/env bash
# hook-block-personify.sh GitHub draft rules: draft PRs and pending reviews need lint only; gh pr ready blocks on review routes.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "${HERE}/.." && pwd)/hook-block-personify.sh"
TMP="$(mktemp -d)"
TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT

export HOME="${TMP}/home"
mkdir -p "${HOME}"
export CLAUDE_CONFIG_DIR="${HOME}/.claude"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_CEILING_DIRECTORIES="${TMP}"
export XDG_CONFIG_HOME="${TMP}/xdg"
export GH_WRAPPER_LIB="${TMP}/no-wrapper.sh"
export GATE_REVIEW_DIR="${TMP}/gate"
export GATE_GH="${HERE}/fixtures/gh-fork-stub.sh"
export COPY_PATHS_FILE="${HERE}/fixtures/copy-paths-none.conf"
export GATE_LINT_VALE="${HERE}/fixtures/vale-stub.sh"
export GATE_RULES_FILE="${TMP}/rules.conf"
printf 'owner=twistedmelonman exempt\n* review\n' >"${GATE_RULES_FILE}"
# shellcheck source=/dev/null
source "${HERE}/fixtures/stub-personify.sh"
_stub_personify "${CLAUDE_CONFIG_DIR}" "${TMP}/personify"
mkdir -p "${GATE_REVIEW_DIR}/pending" "${GATE_REVIEW_DIR}/approved/k1"

pass=0
fail=0
_ok() {
  echo "  PASS  $1"
  pass=$((pass + 1))
}
_no() {
  echo "  FAIL  $1"
  fail=$((fail + 1))
}

_mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "https://github.com/$2.git"
}
REVIEW="${TMP}/review"
EXEMPT="${TMP}/exempt"
_mkrepo "${REVIEW}" beacon-biosignals/x
_mkrepo "${EXEMPT}" twistedmelonman/y

CLEAN="${TMP}/clean.md"
printf 'Adds the thing. Tests cover it.\n' >"${CLEAN}"
DIRTY="${TMP}/dirty.md"
printf 'This is a pivotal moment for the repo.\n' >"${DIRTY}"
_approve() { cp "$1" "${GATE_REVIEW_DIR}/approved/k1/${1##*/}"; }
_unapprove() { rm -f "${GATE_REVIEW_DIR}/approved/k1/"*; }

_case() {
  local label="$1" wrc="$2" wsub="$3" json err rc
  json="$(jq -n --arg c "$5" --arg d "$4" '{tool_input:{command:$c},cwd:$d}')"
  err="$(printf '%s' "${json}" | "${HOOK}" 2>&1 >/dev/null)"
  rc=$?
  if ((rc == wrc)) && [[ "${err}" == *"${wsub}"* ]]; then
    _ok "${label}"
  else
    _no "${label} (rc=${rc}): ${err}"
  fi
}

_unapprove
echo "--- gh pr create ---"
_case "draft, clean body file: passes, no approval" 0 "" "${REVIEW}" "gh pr create --draft --title t --body-file ${CLEAN}"
_case "-d, clean body file: passes" 0 "" "${REVIEW}" "gh pr create -d --title t --body-file ${CLEAN}"
_case "draft, lint error: blocked" 2 "lint errors" "${REVIEW}" "gh pr create --draft --title t --body-file ${DIRTY}"
_case "draft, inline body: blocked" 2 "inline" "${REVIEW}" "gh pr create --draft --title t --body 'Adds it.'"
_case "draft, relative body path: blocked" 2 "not absolute" "${REVIEW}" "gh pr create --draft --title t --body-file clean.md"
_case "--draft only inside a quoted title: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh pr create --title 'why not --draft' --body-file ${CLEAN}"
_case "--draft as the --title value: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh pr create --title --draft --body-file ${CLEAN}"
_case "non-draft, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh pr create --title t --body-file ${CLEAN}"
_approve "${CLEAN}"
_case "non-draft, approved: passes" 0 "" "${REVIEW}" "gh pr create --title t --body-file ${CLEAN}"
_unapprove
_case "draft on an exempt route: passes" 0 "" "${EXEMPT}" "gh pr create --draft --title t --body-file ${DIRTY}"
_case "gh pr edit on a draft is still gated" 2 "no visual approval" "${REVIEW}" "gh pr edit 3 --body-file ${CLEAN}"

echo "--- gh pr ready ---"
_case "ready on a review route: blocked" 2 "GitHub UI" "${REVIEW}" "gh pr ready 3"
_case "ready with -R to a review repo: blocked" 2 "GitHub UI" "${EXEMPT}" "gh pr ready 3 -R beacon-biosignals/x"
_case "ready on an exempt route: passes" 0 "" "${EXEMPT}" "gh pr ready 3"
_case "ready --undo (back to draft): passes" 0 "" "${REVIEW}" "gh pr ready 3 --undo"

echo "--- gh pr review ---"
_case "review --approve alone: passes" 0 "" "${REVIEW}" "gh pr review 3 --approve"
_case "review --comment with body, unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh pr review 3 --comment --body-file ${CLEAN}"
_case "review --request-changes with body, unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh pr review 3 --request-changes --body-file ${CLEAN}"
_approve "${CLEAN}"
_case "review --approve with approved body: passes" 0 "" "${REVIEW}" "gh pr review 3 --approve --body-file ${CLEAN}"
_unapprove

echo "--- gh api .../reviews ---"
EP="repos/beacon-biosignals/x/pulls/3/reviews"
_case "pending review (no event), clean: passes" 0 "" "${REVIEW}" "gh api ${EP} -F body=@${CLEAN}"
_case "pending review, lint error: blocked" 2 "lint errors" "${REVIEW}" "gh api ${EP} -F body=@${DIRTY}"
_case "pending review, inline body: blocked" 2 "inline" "${REVIEW}" "gh api ${EP} -f body=hello"
_case "review with event, unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh api ${EP} -f event=COMMENT -F body=@${CLEAN}"
_case "review with --field event, unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh api ${EP} --field event=APPROVE -F body=@${CLEAN}"
_approve "${CLEAN}"
_case "review with event, approved: passes" 0 "" "${REVIEW}" "gh api ${EP} -f event=COMMENT -F body=@${CLEAN}"
_unapprove
_case "issue comment via api is still gated" 2 "no visual approval" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/issues/3/comments -F body=@${CLEAN}"
mkdir -p "${TMP}/pulls/3"
cp "${CLEAN}" "${TMP}/pulls/3/reviews"
_case "reviews path only in the body file name: still gated" 2 "no visual approval" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/issues/3/comments -F body=@${TMP}/pulls/3/reviews"
_case "quote-split event key: gated" 2 "no visual approval" "${REVIEW}" "gh api ${EP} -f 'ev'ent=APPROVE -F body=@${CLEAN}"
_case "event from a variable: gated" 2 "no visual approval" "${REVIEW}" "gh api ${EP} -f \$E -F body=@${CLEAN}"
_case "submit a pending review (events): blocked" 2 "GitHub UI" "${REVIEW}" "gh api ${EP}/77/events -f event=COMMENT"
_case "submit, quoted review ID: blocked" 2 "GitHub UI" "${REVIEW}" "gh api ${EP}/'77'/events -f event=COMMENT"
_case "submit, review ID from a variable: blocked" 2 "BLOCKED" "${REVIEW}" "gh api ${EP}/\${ID}/events -f event=COMMENT"
_case "graphql, quote-split mutation name: blocked" 2 "GitHub UI" "${REVIEW}" \
  "gh api graphql -f query='mutation { submitPull''RequestReview(input: {pullRequestReviewId: \"X\"}) { clientMutationId } }'"
_case "submit a pending review, exempt route: passes" 0 "" "${EXEMPT}" \
  "gh api repos/twistedmelonman/y/pulls/3/reviews/77/events -f event=COMMENT"
_case "graphql submitPullRequestReview: blocked" 2 "GitHub UI" "${REVIEW}" \
  "gh api graphql -f query='mutation { submitPullRequestReview(input: {pullRequestReviewId: \"X\", event: COMMENT}) { clientMutationId } }'"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
