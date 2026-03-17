#!/usr/bin/env bash
# Hook: Block commits directly to main/master branch
# Enforces branch-based workflow

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

if printf '%s\n' "${cmd}" | grep -qE '^git[[:space:]]' \
   && printf '%s\n' "${cmd}" | grep -qE '[[:space:]]commit([[:space:]]|$)'; then
  git_dir=$(printf '%s\n' "${cmd}" | sed -En 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:]]+).*/\1/p')
  if [[ -n "${git_dir}" ]]; then
    branch=$(git -C "${git_dir}" symbolic-ref --short HEAD 2>/dev/null || echo 'unknown')
  else
    branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo 'unknown')
  fi
  if [[ "${branch}" == 'main' || "${branch}" == 'master' ]]; then
    echo '🛑 BLOCKED: Cannot commit directly to '"${branch}"'.' >&2
    echo '' >&2
    echo 'Create a feature branch first:' >&2
    echo '  git checkout -b claude/feature-name' >&2
    exit 2
  fi
fi
