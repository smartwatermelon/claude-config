#!/usr/bin/env bash
# hook-block-personify.sh: _gate_gh_more, _verify_api_input, _api_dynamic_review. HOOK may name another copy.

set -uo pipefail
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$(cd "${HERE}/.." && pwd)/hook-block-personify.sh}"
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

# JSON request files whose body is CLEAN's exact bytes (trailing newline included).
J_BODY="${TMP}/body.json"
jq -n --rawfile b "${CLEAN}" '{body: $b}' >"${J_BODY}"
J_EVENT="${TMP}/event.json"
jq -n --rawfile b "${CLEAN}" '{body: $b, event: "COMMENT"}' >"${J_EVENT}"
J_PENDING="${TMP}/pending.json"
jq -n --rawfile b "${CLEAN}" '{body: $b, comments: [{path: "a", line: 1, body: $b}]}' >"${J_PENDING}"
J_PENDING_DIRTY="${TMP}/pending-dirty.json"
jq -n --rawfile b "${DIRTY}" '{body: $b}' >"${J_PENDING_DIRTY}"
J_STATE="${TMP}/state.json"
printf '{"state":"closed"}\n' >"${J_STATE}"
J_NESTED="${TMP}/nested.json"
jq -n --rawfile b "${CLEAN}" --rawfile d "${DIRTY}" '{event: "COMMENT", comments: [{path: "a", body: $b}, {path: "b", body: $d}]}' >"${J_NESTED}"
J_GQL="${TMP}/gql.json"
cat >"${J_GQL}" <<'EOF'
{"query":"mutation($b: String!) { addComment(input: {subjectId: \"X\", body: $b}) { clientMutationId } }","variables":{"b":"hi"}}
EOF
J_GQL_READ="${TMP}/gql-read.json"
printf '{"query":"query { viewer { login } }"}\n' >"${J_GQL_READ}"
NOTJSON="${TMP}/not.json"
printf 'not json\n' >"${NOTJSON}"

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

# Round trip: the extracted body must be byte-identical to the approved file, or no hash could ever match.
jq -j '.body' "${J_BODY}" >"${TMP}/roundtrip"
if cmp -s "${TMP}/roundtrip" "${CLEAN}"; then
  _ok "jq -j round-trips the body bytes"
else
  _no "jq -j round-trips the body bytes"
fi

_unapprove
echo "--- gh pr merge ---"
_case "merge --body-file, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh pr merge 3 --squash --body-file ${CLEAN}"
_case "merge -F, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh pr merge 3 --squash -F ${CLEAN}"
_case "merge --body inline: blocked" 2 "inline" "${REVIEW}" "gh pr merge 3 --squash --body 'Adds it.'"
_case "merge -b inline: blocked" 2 "inline" "${REVIEW}" "gh pr merge 3 --squash -b 'Adds it.'"
_case "merge --subject: blocked" 2 "subject" "${REVIEW}" "gh pr merge 3 --squash --subject 'Add it'"
_case "merge -t: blocked" 2 "subject" "${REVIEW}" "gh pr merge 3 --squash -t 'Add it'"
_case "merge -b'text' attached: blocked" 2 "joined" "${REVIEW}" "gh pr merge 3 --squash -b'Adds it.'"
_case "merge -db cluster: blocked" 2 "joined" "${REVIEW}" "gh pr merge 3 -db 'Adds it.'"
_case "release -nText attached: blocked" 2 "joined" "${REVIEW}" "gh release create v1 -nFixes"
_case "close -cText attached: blocked" 2 "joined" "${REVIEW}" "gh issue close 3 -cDone"
_case "merge -sd cluster (no text flag): passes" 0 "" "${REVIEW}" "gh pr merge 3 -sd"
_case "merge with no text flag: passes" 0 "" "${REVIEW}" "gh pr merge 3 --squash --delete-branch"
_case "merge -R to a review repo from an exempt checkout: blocked" 2 "no visual approval" "${EXEMPT}" \
  "gh pr merge 3 -R beacon-biosignals/x --squash --body-file ${CLEAN}"
_case "merge under xargs: blocked" 2 "xargs" "${REVIEW}" "echo 3 | xargs gh pr merge --squash --body-file ${CLEAN}"
_approve "${CLEAN}"
_case "merge --body-file, approved: passes" 0 "" "${REVIEW}" "gh pr merge 3 --squash --body-file ${CLEAN}"
_case "merge --subject with approved body: still blocked" 2 "subject" "${REVIEW}" \
  "gh pr merge 3 --squash --subject 'Add it' --body-file ${CLEAN}"
_unapprove
_case "merge on an exempt route, inline subject and body: passes" 0 "" "${EXEMPT}" \
  "gh pr merge 3 --squash --subject 'Add it' --body 'Adds it.'"
_case "merge on an exempt route, dirty body file: passes" 0 "" "${EXEMPT}" "gh pr merge 3 --squash --body-file ${DIRTY}"

echo "--- gh release create/edit ---"
_case "release create --notes-file, unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh release create v1 --notes-file ${CLEAN}"
_case "release create -F, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh release create v1 -F ${CLEAN}"
_case "release edit --notes inline: blocked" 2 "inline" "${REVIEW}" "gh release edit v1 --notes 'Fixes it.'"
_case "release create -n inline: blocked" 2 "inline" "${REVIEW}" "gh release create v1 -n 'Fixes it.'"
_case "release create --generate-notes: passes" 0 "" "${REVIEW}" "gh release create v1 --generate-notes"
_approve "${CLEAN}"
_case "release create --notes-file, approved: passes" 0 "" "${REVIEW}" "gh release create v1 --notes-file ${CLEAN}"
_case "release edit -F, approved: passes" 0 "" "${REVIEW}" "gh release edit v1 -F ${CLEAN}"
_unapprove
_case "release on an exempt route, inline notes: passes" 0 "" "${EXEMPT}" "gh release create v1 --notes 'Fixes it.'"

echo "--- gh issue/pr close --comment ---"
_case "issue close --comment: blocked" 2 "comment --body-file" "${REVIEW}" "gh issue close 3 --comment 'Done.'"
_case "issue close -c: blocked" 2 "comment --body-file" "${REVIEW}" "gh issue close 3 -c 'Done.'"
_case "pr close --comment: blocked" 2 "comment --body-file" "${REVIEW}" "gh pr close 3 --comment 'Superseded.'"
_case "pr close --comment=: blocked" 2 "comment --body-file" "${REVIEW}" "gh pr close 3 --comment=Superseded"
_case "issue close with no comment: passes" 0 "" "${REVIEW}" "gh issue close 3 --reason completed"
_case "pr close --delete-branch: passes" 0 "" "${REVIEW}" "gh pr close 3 --delete-branch"
_case "issue close --comment on an exempt route: passes" 0 "" "${EXEMPT}" "gh issue close 3 --comment 'Done.'"

echo "--- gh api --input ---"
CEP="repos/beacon-biosignals/x/issues/3/comments"
REP="repos/beacon-biosignals/x/pulls/3/reviews"
_case "comment via --input, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh api ${CEP} --input ${J_BODY}"
_case "comment via --input=, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh api ${CEP} --input=${J_BODY}"
_case "--input - (stdin): blocked" 2 "stdin" "${REVIEW}" "jq -n '{body:\"x\"}' | gh api ${CEP} --input -"
_case "--input /dev/stdin: blocked" 2 "stdin" "${REVIEW}" "gh api ${CEP} --input /dev/stdin"
_case "--input relative path: blocked" 2 "absolute" "${REVIEW}" "gh api ${CEP} --input body.json"
_case "--input from a variable: blocked" 2 "absolute" "${REVIEW}" "gh api ${CEP} --input \$F"
_case "--input not JSON: blocked" 2 "not valid JSON" "${REVIEW}" "gh api ${CEP} --input ${NOTJSON}"
_case "--input with no body key: passes" 0 "" "${REVIEW}" "gh api -X PATCH repos/beacon-biosignals/x/issues/3 --input ${J_STATE}"
_case "pending review via --input (no event), clean: passes" 0 "" "${REVIEW}" "gh api ${REP} --input ${J_PENDING}"
_case "pending review via --input, lint error: blocked" 2 "lint errors" "${REVIEW}" "gh api ${REP} --input ${J_PENDING_DIRTY}"
_case "review via --input with event, unapproved: blocked" 2 "no visual approval" "${REVIEW}" "gh api ${REP} --input ${J_EVENT}"
_case "review --input, event only on a nested body: one unapproved: blocked" 2 "no visual approval" "${REVIEW}" \
  "gh api ${REP} --input ${J_NESTED}"
_case "graphql --input with body: blocked" 2 "GraphQL" "${REVIEW}" "gh api graphql --input ${J_GQL}"
_case "graphql --input read-only query: passes" 0 "" "${REVIEW}" "gh api graphql --input ${J_GQL_READ}"
_case "--input under xargs: blocked" 2 "xargs" "${REVIEW}" "echo ${J_BODY} | xargs gh api ${CEP} --input"
_approve "${CLEAN}"
_case "comment via --input, approved: passes" 0 "" "${REVIEW}" "gh api ${CEP} --input ${J_BODY}"
_case "review via --input with event, approved: passes" 0 "" "${REVIEW}" "gh api ${REP} --input ${J_EVENT}"
_case "nested bodies, one approved one not: blocked" 2 "no visual approval" "${REVIEW}" "gh api ${REP} --input ${J_NESTED}"
_unapprove
_case "--input on an exempt route, unapproved: passes" 0 "" "${EXEMPT}" \
  "gh api repos/twistedmelonman/y/issues/3/comments --input ${J_BODY}"
_case "--input - on an exempt route: passes" 0 "" "${EXEMPT}" \
  "gh api repos/twistedmelonman/y/issues/3/comments --input -"

echo "--- review IDs from command substitution ---"
_case "submit, PR ID from \$( ) with a space: blocked" 2 "BLOCKED" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/pulls/\$(printf 3)/reviews/77/events -f event=COMMENT"
_case "submit, review ID from \$( ) with a pipe: blocked" 2 "BLOCKED" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/pulls/3/reviews/\$(echo 77 | cat)/events -f event=COMMENT"
_case "submit, review ID from backticks: blocked" 2 "BLOCKED" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/pulls/3/reviews/\`printf 77\`/events -f event=APPROVE"
_case "submit, review ID from \${N}: blocked" 2 "BLOCKED" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/pulls/3/reviews/\${N}/events -f event=COMMENT"
_case "literal IDs on an exempt route: passes" 0 "" "${EXEMPT}" \
  "gh api repos/twistedmelonman/y/pulls/3/reviews/77/events -f event=COMMENT"
_case "GET with \$( ) and no review endpoint: passes" 0 "" "${REVIEW}" \
  "gh api repos/beacon-biosignals/x/issues/\$(printf 3)"

echo "--- GraphQL markPullRequestReadyForReview ---"
# The mutation names a node ID, not a repo, so no route resolves: it blocks from every checkout.
RDY="Ready for review in the GitHub UI"
MUT='mutation { markPullRequestReadyForReview(input: {pullRequestId: "PR_kwDOAB"}) { clientMutationId } }'
J_READY="${TMP}/gql-ready.json"
jq -n --arg q "${MUT}" '{query: $q}' >"${J_READY}"
_case "ready mutation via -f query=, review checkout: blocked" 2 "${RDY}" "${REVIEW}" "gh api graphql -f query='${MUT}'"
_case "ready mutation via --raw-field query=: blocked" 2 "${RDY}" "${REVIEW}" "gh api graphql --raw-field query='${MUT}'"
_case "ready mutation via -F query=: blocked" 2 "${RDY}" "${REVIEW}" "gh api graphql -F query='${MUT}'"
_case "ready mutation via --field=query=: blocked" 2 "${RDY}" "${REVIEW}" "gh api graphql --field=query='${MUT}'"
_case "ready mutation across lines: blocked" 2 "${RDY}" "${REVIEW}" \
  "gh api graphql -f query='mutation {
  markPullRequestReadyForReview(input: {pullRequestId: \"PR_kwDOAB\"}) { clientMutationId }
}'"
_case "ready mutation from an exempt checkout (no route): blocked" 2 "${RDY}" "${EXEMPT}" \
  "gh api graphql -f query='${MUT}'"
_case "ready mutation via --input: blocked" 2 "${RDY}" "${REVIEW}" "gh api graphql --input ${J_READY}"
_case "ready mutation via --input from an exempt checkout: blocked" 2 "${RDY}" "${EXEMPT}" \
  "gh api graphql --input ${J_READY}"
_case "PR body that mentions the mutation: passes" 0 "" "${EXEMPT}" \
  "gh pr create -R twistedmelonman/y --title t --body 'Blocks gh api graphql markPullRequestReadyForReview on review routes.'"
_case "read-only graphql query: passes" 0 "" "${REVIEW}" "gh api graphql -f query='query { viewer { login } }'"

echo ""
echo "${pass} passed, ${fail} failed"
((fail == 0))
