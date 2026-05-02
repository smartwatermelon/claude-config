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

echo "RESOLVED_OWNER=${OWNER} RESOLVED_REPO=${REPO}" >&2

# Preflight: confirm the PR exists in the resolved repo before continuing.
# Without this, running from the wrong CWD silently polls the wrong repo and
# produces confusing downstream errors (jq blowups on 404 error bodies etc).
if ! gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}" --jq '.number' >/dev/null 2>&1; then
  echo "ERROR: PR #${PR_NUMBER} not found in ${OWNER}/${REPO}." >&2
  echo "  If the PR is in a different repo, set POSTPUSH_OWNER=<owner> POSTPUSH_REPO=<repo>" >&2
  echo "  or re-run from that repo's directory." >&2
  exit 1
fi

CURRENT_COMMIT="${POSTPUSH_CURRENT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo "")}"
if [[ -z "${CURRENT_COMMIT}" ]]; then
  echo "ERROR: cannot determine current commit" >&2
  exit 1
fi

COMMIT_TIMESTAMP="${POSTPUSH_COMMIT_TIMESTAMP:-$(TZ=UTC git show -s --format=%cd --date=format:'%Y-%m-%dT%H:%M:%SZ' "${CURRENT_COMMIT}" 2>/dev/null || echo "")}"

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
#
# _safe_api_array: `gh api` prints its error body to stdout BEFORE exiting nonzero,
# so `{ gh api ... || echo "[]"; }` leaves the file with BOTH the error JSON object
# and "[]" concatenated — then jq's `.[0] + .[1]` tries to add object+array and
# explodes. Capture output to a variable first, shape-validate as a JSON array,
# and only write `[]` if validation fails. Preserves empty-list semantics without
# letting malformed/error bodies leak through.
_safe_api_array() {
  local url="$1"
  local body
  if body=$(gh api "${url}" 2>/dev/null) \
    && echo "${body}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "${body}"
  else
    printf '%s\n' "[]"
  fi
}

# _fetch_issue_comments_gql: GraphQL fetch for PR conversation (issues/comments).
# Why GraphQL instead of REST: the REST issues/comments endpoint does not return
# `isMinimized`, so previously-collapsed bot comments (e.g. PASS reviews
# minimized by claude-blocking-review.yml's minimizeComment mutation) were still
# surfaced as findings. GraphQL exposes `isMinimized`, letting us skip them.
#
# The --jq projection reshapes GraphQL nodes into the REST-compatible JSON
# shape the python parser expects (user.login, created_at, body, path, line),
# so the parser block stays unchanged. Bot authors are reported by GraphQL as
# `Bot` __typename with login stripped of the `[bot]` suffix; we re-append it
# so BOT_PATTERN (which expects `claude[bot]` etc.) still matches.
_fetch_issue_comments_gql() {
  local owner="$1" repo="$2" number="$3"
  # Heredoc keeps $owner/$name/$number literal — they're GraphQL variables, not
  # bash expansions. `gh api -f owner=... -f name=... -F number=...` substitutes them.
  local query
  query=$(
    cat <<'GQLEOF'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      comments(last: 100) {
        nodes {
          body
          createdAt
          isMinimized
          author {
            __typename
            login
          }
        }
      }
    }
  }
}
GQLEOF
  )
  # Reshape GraphQL nodes into REST-compatible objects so the python parser is
  # unchanged. Bot authors come back from GraphQL with `[bot]` stripped from
  # login; re-append it so BOT_PATTERN matches `claude[bot]`, `sentry[bot]`, etc.
  local jq_filter
  jq_filter=$(
    cat <<'JQEOF'
.data.repository.pullRequest.comments.nodes
  | map(select(.isMinimized == false))
  | map({
      user: { login: (
        if .author == null then ""
        elif .author.__typename == "Bot" then (.author.login + "[bot]")
        else .author.login
        end
      ) },
      created_at: .createdAt,
      body: .body,
      path: "",
      line: null
    })
JQEOF
  )
  local body
  if body=$(gh api graphql \
        -f query="${query}" \
        -f owner="${owner}" -f name="${repo}" -F number="${number}" \
        --jq "${jq_filter}" 2>/dev/null) \
    && echo "${body}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "${body}"
  else
    printf '%s\n' "[]"
  fi
}

_safe_api_array "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" >"${TMPFILE}_pulls"
_fetch_issue_comments_gql "${OWNER}" "${REPO}" "${PR_NUMBER}" >"${TMPFILE}_issues"
jq -s '.[0] + .[1]' "${TMPFILE}_pulls" "${TMPFILE}_issues" >"${TMPFILE}" || echo "[]" >"${TMPFILE}"
rm -f "${TMPFILE}_pulls" "${TMPFILE}_issues"

python3 - "${TMPFILE}" "${CURRENT_COMMIT}" "${BOT_PATTERN}" "${COMMIT_TIMESTAMP}" <<'PYEOF'
import sys, json, re

comments_file    = sys.argv[1]
current_commit   = sys.argv[2]
bot_pattern      = sys.argv[3]
commit_timestamp = sys.argv[4] if len(sys.argv) > 4 else ""

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
    else:
        # issues/comments: filter by created_at >= commit_timestamp to exclude stale
        # findings from prior loop iterations. If either timestamp is unavailable,
        # include the comment (fail open — better to surface a stale finding than miss a real one).
        if commit_timestamp:
            created_at = c.get("created_at", "")
            if created_at and created_at < commit_timestamp:
                continue
    body = c.get("body", "").strip()
    if not body:
        continue
    path = c.get("path", "")
    line = c.get("line") or c.get("original_line") or ""
    body_oneline = " | ".join(body.splitlines())
    print(f'FINDING source={login} file="{path}" line={line} comment={body_oneline}')
PYEOF
