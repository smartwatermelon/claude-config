#!/usr/bin/env bash
# post-push-status.sh <pr_number>
# Output: CI_STATE=<state> + FINDING lines
# PAT-compatible: uses gh api GraphQL/REST, not gh pr checks.
set -euo pipefail

PR_NUMBER="${1:?Usage: post-push-status.sh <pr_number>}"

OWNER="${POSTPUSH_OWNER:-}"
REPO="${POSTPUSH_REPO:-}"

if [[ -z "${OWNER}" ]] || [[ -z "${REPO}" ]]; then
  REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if [[ -z "${REMOTE_URL}" ]]; then
    echo "ERROR: no git remote 'origin' found" >&2
    exit 1
  fi
  if [[ "${REMOTE_URL}" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
  else
    echo "ERROR: cannot parse owner/repo from remote: ${REMOTE_URL}" >&2
    exit 1
  fi
fi

CURRENT_COMMIT="${POSTPUSH_CURRENT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo "")}"
if [[ -z "${CURRENT_COMMIT}" ]]; then
  echo "ERROR: cannot determine current commit" >&2
  exit 1
fi

GQL_QUERY=$(
  cat <<'GQLEOF'
  query($owner:String!, $repo:String!, $number:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$number) {
        commits(last:1) {
          nodes {
            commit {
              statusCheckRollup {
                state
              }
            }
          }
        }
      }
    }
  }
GQLEOF
)

GQL_STDERR=$(mktemp /tmp/post-push-gql-err.XXXXXX)
TMPFILE=$(mktemp /tmp/post-push-comments.XXXXXX.json)
trap 'rm -f "${GQL_STDERR}" "${TMPFILE}" "${TMPFILE}_pulls" "${TMPFILE}_issues"' EXIT

CI_JSON=$(gh api graphql -f query="${GQL_QUERY}" \
  -f owner="${OWNER}" -f repo="${REPO}" -F number="${PR_NUMBER}" 2>"${GQL_STDERR}" || true)

if [[ -z "${CI_JSON}" ]]; then
  GQL_ERR=$(cat "${GQL_STDERR}")
  echo "WARNING: GraphQL CI status fetch failed: ${GQL_ERR:-no output}" >&2
fi

CI_STATE=$(echo "${CI_JSON}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    nodes=d['data']['repository']['pullRequest']['commits']['nodes']; \
    rollup=nodes[0]['commit']['statusCheckRollup'] if nodes else None; \
    print(rollup['state'] if rollup else 'UNKNOWN')" 2>/dev/null \
  || echo "UNKNOWN")

echo "CI_STATE=${CI_STATE}"

BOT_PATTERN='sentry\[bot\]|claude\[bot\]|coderabbit\[bot\]'
# Note: fetches only page 1 (default 30 comments). --paginate is intentionally omitted:
# it concatenates raw JSON arrays as "[...][...]" which is invalid JSON and breaks parsing.
# Bot review comments typically appear early, so page 1 is sufficient in practice.
#
# Fetch both inline diff comments (pulls/comments) and PR conversation comments
# (issues/comments). Bots like sentry[bot] post to issues/comments (the PR conversation
# thread); code review bots typically post to pulls/comments (inline diff comments).
{ gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" 2>/dev/null || echo "[]"; } >"${TMPFILE}_pulls"
{ gh api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" 2>/dev/null || echo "[]"; } >"${TMPFILE}_issues"
jq -s '.[0] + .[1]' "${TMPFILE}_pulls" "${TMPFILE}_issues" >"${TMPFILE}" || echo "[]" >"${TMPFILE}"
rm -f "${TMPFILE}_pulls" "${TMPFILE}_issues"

python3 - "${TMPFILE}" "${CURRENT_COMMIT}" "${BOT_PATTERN}" <<'PYEOF'
import sys, json, re

comments_file  = sys.argv[1]
current_commit = sys.argv[2]
bot_pattern    = sys.argv[3]

try:
    with open(comments_file) as fh:
        comments = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    print(f"WARNING: could not parse PR comments: {exc}", file=sys.stderr)
    sys.exit(0)

if not isinstance(comments, list):
    print("WARNING: unexpected PR comments shape (not a list)", file=sys.stderr)
    sys.exit(0)

for c in comments:
    login = c.get("user", {}).get("login", "")
    if not re.search(bot_pattern, login):
        continue
    # pulls/comments have original_commit_id; issues/comments do not
    if "original_commit_id" in c:
        if c["original_commit_id"] != current_commit:
            continue
    # For issues/comments, include all matching-bot comments (no commit filter available)
    body = c.get("body", "").strip()
    if not body:
        continue
    path = c.get("path", "")
    line = c.get("line") or c.get("original_line") or ""
    body_oneline = " | ".join(body.splitlines())
    print(f'FINDING source={login} file="{path}" line={line} comment={body_oneline}')
PYEOF
