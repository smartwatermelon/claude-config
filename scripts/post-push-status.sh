#!/usr/bin/env bash
# post-push-status.sh <N | OWNER/REPO#N | PR URL>
# Stdout: RESOLVED_PR, CI_STATE, FINDING lines. Uses gh api (PAT-safe).

# Exit 2: PR merged/closed (PR_STATE= line). Exit 3: PR head is not the
# local HEAD (HEAD_MISMATCH). Both print CI_STATE=UNKNOWN.
set -euo pipefail

PR_ARG="${1:?Usage: post-push-status.sh <N | OWNER/REPO#N | PR URL>}"

# Owner and name are each one path segment: no slashes, no "." or "..".
# Same rules as validate_repo_slug in hooks/merge-lock.sh.
validate_repo_slug() {
  local slug="$1"
  local owner="${slug%%/*}"
  local name="${slug#*/}"
  [[ "${slug}" == */* ]] || return 1
  [[ "${name}" != */* ]] || return 1
  [[ "${owner}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "${name}" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "${owner}" != "." && "${owner}" != ".." ]] || return 1
  [[ "${name}" != "." && "${name}" != ".." ]] || return 1
  return 0
}

# Resolve owner and repo from a git remote URL. Echoes "<owner> <repo>";
# returns nonzero when the URL carries no owner/repo pair.
#
# The host is deliberately NOT validated (claude-config#456). The previous
# pattern required a literal `github.com`, which broke every per-account SSH
# host alias — `git@github-<account>:owner/repo.git`, the standard multi-account
# setup — because such a URL has no `github.com` substring at all. What this
# script needs is owner/repo; the host is git's business, not ours.
#
# Handled shapes: scp-style (`git@host:owner/repo.git`), https, ssh://, with
# or without a `.git` suffix, a trailing slash, or an embedded `user@`.
#
# The repo name is matched with `[^/]+` rather than the old `[^/.]+`: the
# latter stopped at the first dot, silently resolving `dot.files.git` to repo
# `dot` and polling the wrong repo instead of failing loudly.
parse_remote_url() {
  local _url="$1" _u _scheme=0
  # A remote URL names a host, which means it carries a scheme, a `user@`, or
  # an scp-style `host:`. Without one of those this is a local filesystem path,
  # and coercing `/local/path` into owner=local repo=path would send the poll
  # at a repo that does not exist instead of reporting the real problem.
  if [[ "${_url}" != *://* ]] && [[ "${_url}" != *@* ]] && [[ "${_url}" != *:* ]]; then
    return 1
  fi
  # `file://` is a local path wearing a scheme. Reject it for the same reason.
  [[ "${_url}" == file://* ]] && return 1
  _u="${_url%/}"  # trailing slash
  _u="${_u%.git}" # .git suffix
  if [[ "${_u}" == *://* ]]; then
    _u="${_u#*://}"
    _scheme=1
  fi
  _u="${_u#*@}" # user: git@ user@
  if [[ ${_scheme} -eq 1 ]]; then
    # URL form: the host (with any :port) is its own leading path segment and
    # must be DROPPED, not absorbed. Relying on the pattern below to swallow it
    # made `ssh://git@host/repo.git` resolve to owner=host — a bogus owner
    # rather than the loud failure this function promises.
    [[ "${_u}" == */* ]] || return 1
    _u="${_u#*/}"
  else
    # scp-style `host:owner/repo`; the colon separates host from path.
    _u="${_u#*:}"
  fi
  if [[ "${_u}" =~ ^(.*/)?([^/]+)/([^/]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

OWNER="${POSTPUSH_OWNER:-}"
REPO="${POSTPUSH_REPO:-}"
# 1 when the caller named the repo, so the PR need not match the local HEAD.
EXPLICIT_REPO=0
if [[ -n "${OWNER}" ]] && [[ -n "${REPO}" ]]; then
  EXPLICIT_REPO=1
fi

# Same notation as merge-lock's normalize_pr_entry, minus `name#N`:
# its owner would come from the cwd.
_pr_ref="${PR_ARG}"
if [[ "${_pr_ref}" =~ ^https?://github\.com/([^/[:space:]]+/[^/[:space:]]+)/pull/([0-9]+)/?$ ]]; then
  _pr_ref="${BASH_REMATCH[1]}#${BASH_REMATCH[2]}"
fi
_pr_ref="${_pr_ref#\#}"
if [[ "${_pr_ref}" == *"#"* ]]; then
  _slug="${_pr_ref%%#*}"
  PR_NUMBER="${_pr_ref#*#}"
  if ! validate_repo_slug "${_slug}"; then
    echo "ERROR: invalid repo '${_slug}' in '${PR_ARG}' (expected OWNER/REPO#N)" >&2
    exit 1
  fi
  OWNER="${_slug%%/*}"
  REPO="${_slug#*/}"
  EXPLICIT_REPO=1
else
  PR_NUMBER="${_pr_ref}"
fi
if [[ ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: invalid PR '${PR_ARG}' (expected N, OWNER/REPO#N, or a PR URL)" >&2
  exit 1
fi

# owner/repo of the cwd's origin, or empty. Used to resolve a bare N and to
# name the local checkout when the PR head does not match it.
LOCAL_SLUG=""
REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ -n "${REMOTE_URL}" ]] && PARSED=$(parse_remote_url "${REMOTE_URL}"); then
  LOCAL_SLUG="${PARSED%% *}/${PARSED##* }"
fi

if [[ -z "${OWNER}" ]] || [[ -z "${REPO}" ]]; then
  if [[ -z "${REMOTE_URL}" ]]; then
    echo "ERROR: no git remote 'origin' found" >&2
    echo "  Pass OWNER/REPO#N to name the repo explicitly." >&2
    exit 1
  fi
  if [[ -n "${LOCAL_SLUG}" ]]; then
    OWNER="${LOCAL_SLUG%%/*}"
    REPO="${LOCAL_SLUG#*/}"
  else
    echo "ERROR: cannot parse owner/repo from remote: ${REMOTE_URL}" >&2
    echo "  Pass OWNER/REPO#N, or set POSTPUSH_OWNER=<owner> POSTPUSH_REPO=<repo>" >&2
    exit 1
  fi
fi

echo "RESOLVED_OWNER=${OWNER} RESOLVED_REPO=${REPO}" >&2
# On stdout too: a caller that greps stdout for CI_STATE must also be able to
# see which PR that state belongs to (claude-config#714).
echo "RESOLVED_PR=${OWNER}/${REPO}#${PR_NUMBER}"

# Preflight: fetch state and head SHA. Fields are space-separated and
# never empty, so `read` cannot shift them.
PR_META=$(gh api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}" \
  --jq '"\(.state) \(if .merged_at then "merged" else "unmerged" end) \(.head.sha)"' 2>/dev/null || echo "")
PR_STATE="" PR_MERGED="" PR_HEAD_SHA=""
read -r PR_STATE PR_MERGED PR_HEAD_SHA <<<"${PR_META}" || true
if [[ -z "${PR_STATE}" ]] || [[ ! "${PR_HEAD_SHA}" =~ ^[0-9a-f]+$ ]]; then
  echo "ERROR: PR #${PR_NUMBER} not found in ${OWNER}/${REPO}." >&2
  echo "  If the PR is in a different repo, pass OWNER/REPO#N" >&2
  echo "  or re-run from that repo's directory." >&2
  exit 1
fi

# A merged or closed PR's rollup says nothing about the push being polled.
if [[ "${PR_STATE}" != "open" ]]; then
  if [[ "${PR_MERGED}" == "merged" ]]; then
    _state_word="MERGED"
  else
    _state_word="CLOSED"
  fi
  echo "PR_STATE=${_state_word}: ${OWNER}/${REPO}#${PR_NUMBER} is ${_state_word}, so its CI does not describe a new push. If you meant a PR in another repo, pass OWNER/REPO#N."
  echo "CI_STATE=UNKNOWN"
  exit 2
fi

CURRENT_COMMIT="${POSTPUSH_CURRENT_COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo "")}"
if [[ -z "${CURRENT_COMMIT}" ]]; then
  if [[ "${EXPLICIT_REPO}" -eq 1 ]]; then
    # No local checkout to compare against; the caller named the repo, so
    # filter findings by the PR head.
    CURRENT_COMMIT="${PR_HEAD_SHA}"
  else
    echo "ERROR: cannot determine current commit" >&2
    exit 1
  fi
fi

# PR numbers collide across repos (#714). With a bare N, a head mismatch
# may mean the wrong PR, so the rollup is not trusted.
if [[ "${CURRENT_COMMIT}" != "${PR_HEAD_SHA}" ]]; then
  _local_desc="local HEAD in ${LOCAL_SLUG:-(no parsable origin)} ($(pwd))"
  echo "WARNING: HEAD_MISMATCH: ${OWNER}/${REPO}#${PR_NUMBER} head is ${PR_HEAD_SHA}, but ${_local_desc} is ${CURRENT_COMMIT}."
  if [[ "${EXPLICIT_REPO}" -eq 0 ]]; then
    echo "  The PR number may belong to another repo, or the push has not landed yet. Pass OWNER/REPO#N to poll a PR from another checkout."
    echo "CI_STATE=UNKNOWN"
    exit 3
  fi
  echo "  The repo was named explicitly, so polling continues; findings are filtered by the PR head."
  CURRENT_COMMIT="${PR_HEAD_SHA}"
fi

COMMIT_TIMESTAMP="${POSTPUSH_COMMIT_TIMESTAMP:-$(TZ=UTC git show -s --format=%cd --date=format:'%Y-%m-%dT%H:%M:%SZ' "${CURRENT_COMMIT}" 2>/dev/null || echo "")}"

# Collapsed to a single line (newlines stripped) before being passed to `gh
# api graphql -f query=...`. GraphQL treats newlines as insignificant
# whitespace, so this is semantically identical to the multi-line form.
# Required because some `gh` wrappers (e.g. an off-org draft-PR enforcement
# shim) round-trip argv through `printf '%s\n' "$@" | mapfile -t`, which
# splits any argument containing an embedded newline into multiple bogus
# arguments -- producing errors like "accepts 1 arg(s), received 15" from
# the underlying `gh` binary. A single-line query survives that round-trip.
GQL_QUERY=$(
  cat <<'GQLEOF' | tr '\n' ' '
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
# Xs must be trailing: BSD mktemp leaves "XXXXXX.json" literal, so every run
# would share one fixed path.
TMPFILE=$(mktemp /tmp/post-push-comments.XXXXXX)
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
  # Collapsed to a single line (newlines stripped, see GQL_QUERY comment above)
  # so it survives `gh` wrapper argv round-trips that split on embedded newlines.
  local query
  query=$(
    cat <<'GQLEOF' | tr '\n' ' '
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
  # Collapsed to a single line (newlines stripped, see GQL_QUERY comment
  # above) so it survives `gh` wrapper argv round-trips that split on
  # embedded newlines. jq treats newlines as insignificant whitespace here
  # (no line comments in this filter), so behavior is unchanged.
  # NOTE: do not add `#`-style jq line comments inside this heredoc --
  # `tr '\n' ' '` would merge them into the following line instead of
  # terminating them, silently corrupting the filter.
  local jq_filter
  jq_filter=$(
    cat <<'JQEOF' | tr '\n' ' '
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
