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

# One plain `gh api` review create from a JSON file with no event: it stays PENDING, approving nothing.
is_pending_review_create() {
  local words word path="" endpoints=0 inputs=0 i
  # No quoting, globbing, expansion, chaining or redirection: the shell must pass the path as written.
  [[ "${cmd}" != *[\;\&\|\<\>\`\$\'\"\\\*\?\[\]\{\}\~]* && "${cmd}" != *$'\n'* ]] || return 1
  read -ra words <<<"${cmd}"
  i=0
  [[ "${words[i]:-}" == "command" ]] && i=$((i + 1))
  [[ "${words[i]:-}" =~ ^(/opt/homebrew/bin/|/usr/local/bin/)?gh$ && "${words[i + 1]:-}" == "api" ]] || return 1
  i=$((i + 2))
  while ((i < ${#words[@]})); do
    word="${words[i]}"
    case "${word}" in
      --input)
        i=$((i + 1))
        path="${words[i]:-}"
        inputs=$((inputs + 1))
        ;;
      --input=*)
        path="${word#--input=}"
        inputs=$((inputs + 1))
        ;;
      -X | --method)
        i=$((i + 1))
        [[ "${words[i]:-}" == "POST" ]] || return 1
        ;;
      -XPOST | --method=POST | --silent | --include | -i | --verbose) ;;
      --jq | -q) i=$((i + 1)) ;;
      --jq=*) ;;
      *)
        [[ "${word}" =~ ^/?repos/[^/]+/[^/]+/pulls/[0-9]+/reviews$ ]] || return 1
        endpoints=$((endpoints + 1))
        ;;
    esac
    i=$((i + 1))
  done
  ((endpoints == 1 && inputs == 1)) || return 1
  # Absolute only: the hook cannot know the shell's working directory.
  [[ "${path}" == /* && -f "${path}" ]] || return 1
  # Exactly one JSON document, so a second document cannot carry an event.
  jq -se 'length == 1 and (.[0] | type == "object" and (has("event") | not))' "${path}" >/dev/null 2>&1
}

# 1. gh pr review with --approve, -a, or a short-flag cluster holding a.
if printf '%s\n' "${cmd}" | grep -qE '(^|[^[:alnum:]_-])pr[[:space:]]+review([[:space:]]|$)'; then
  if printf '%s\n' "${cmd}" | grep -qE '(^|[[:space:]])(--approve(=|[[:space:]]|$)|-[[:alpha:]]*a[[:alpha:]]*([[:space:]]|=|$))'; then
    block "gh pr review --approve"
  fi
fi

# 2. A REST reviews endpoint, from any program: APPROVE, or any write whose event this hook cannot see.
# A pending review (no event, read from a file this hook checks) is allowed.
if printf '%s\n' "${cmd}" | grep -qE 'pulls/[^/[:space:]]+/reviews'; then
  if printf '%s\n' "${cmd}" | grep -qiE 'approve'; then
    block "a review event of APPROVE"
  fi
  # A read may name GET; drop that before looking for a write.
  rest=$(printf '%s\n' "${cmd}" | sed -E 's/(^|[[:space:]])(-X|--method|--request)([[:space:]]+|=)GET([[:space:]]|$)/\1\4/g; s/(^|[[:space:]])-XGET([[:space:]]|$)/\1\2/g')
  if printf '%s\n' "${rest}" | grep -qE '(^|[[:space:]])(-[fFdX]|--(field|raw-field|input|method|data|data-raw|data-binary|json|request)([[:space:]]|=|$))|(^|[[:space:]])-[fFdX][^[:space:]]'; then
    is_pending_review_create || block "a write to a pull request reviews endpoint"
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
