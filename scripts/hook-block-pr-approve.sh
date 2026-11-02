#!/usr/bin/env bash
# Hook: block an agent from approving a PR. Under the "review" policy, Andrew's approval is the merge lock.

# Not covered: commands built from variables, eval or script files (#658), and browser clicks as Andrew.

set -euo pipefail

cmd=""
block() {
  printf '%s BLOCKED PR APPROVE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: approving a pull request is a human-only action (%s).\n' "$1" >&2
  printf '\n' >&2
  printf "Andrew's GitHub approval is the merge lock on review-policy repos, so an agent never approves.\n" >&2
  printf 'Ask Andrew to review the PR in GitHub, then run gh pr merge <N> --squash --delete-branch and report its result as is.\n' >&2
  exit 2
}

# Exit 1 would be a non-blocking error, so input this hook cannot parse blocks.
input=$(cat) || block "unreadable hook input"
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null) || block "unparseable hook input"
[[ -n "${cmd}" ]] || exit 0

# 1. gh pr review with --approve, -a, or a short-flag cluster holding a.
if printf '%s\n' "${cmd}" | grep -qE '(^|[^[:alnum:]_-])pr[[:space:]]+review([[:space:]]|$)'; then
  if printf '%s\n' "${cmd}" | grep -qE '(^|[[:space:]])(--approve(=|[[:space:]]|$)|-[[:alpha:]]*a[[:alpha:]]*([[:space:]]|=|$))'; then
    block "gh pr review --approve"
  fi
fi

# 2. A REST reviews endpoint, from any program: APPROVE, or any write whose event this hook cannot see.
if printf '%s\n' "${cmd}" | grep -qE 'pulls/[^/[:space:]]+/reviews'; then
  if printf '%s\n' "${cmd}" | grep -qiE 'approve'; then
    block "a review event of APPROVE"
  fi
  # A read may name GET; drop that before looking for a write.
  rest=$(printf '%s\n' "${cmd}" | sed -E 's/(^|[[:space:]])(-X|--method|--request)([[:space:]]+|=)GET([[:space:]]|$)/\1\4/g; s/(^|[[:space:]])-XGET([[:space:]]|$)/\1\2/g')
  if printf '%s\n' "${rest}" | grep -qE '(^|[[:space:]])(-[fFdX]|--(field|raw-field|input|method|data|data-raw|data-binary|json|request)([[:space:]]|=|$))|(^|[[:space:]])-[fFdX][^[:space:]]'; then
    block "a write to a pull request reviews endpoint"
  fi
fi

# 3. GraphQL review mutations, and a GraphQL query read from a file this hook cannot see.
if printf '%s\n' "${cmd}" | grep -qiE 'addPullRequestReview([^[:alnum:]]|$)|submitPullRequestReview'; then
  block "a GraphQL review mutation"
fi
if printf '%s\n' "${cmd}" | grep -qE '(^|[^[:alnum:]_-])api[[:space:]]+graphql([[:space:]]|$)'; then
  if printf '%s\n' "${cmd}" | grep -qE '(^|[[:space:]])--input([[:space:]]|=|$)|query=@'; then
    block "a GraphQL query read from a file"
  fi
fi

exit 0
