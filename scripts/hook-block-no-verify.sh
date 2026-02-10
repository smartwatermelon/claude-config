#!/usr/bin/env bash
# Hook: Block --no-verify flag on any command
# This enforces mandatory code review before commits

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

if printf '%s\n' "$cmd" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: $cmd" >>"${HOME}/.claude/blocked-commands.log"
  echo '🛑 BLOCKED: --no-verify is forbidden. Code review is mandatory.' >&2
  echo '' >&2
  echo 'The review hooks exist to catch bugs before CI. Skipping them wastes money.' >&2
  echo '' >&2
  echo 'If review times out, retry or fix the timeout:' >&2
  echo '  git config review.timeout 300' >&2
  echo '' >&2
  echo 'For genuine emergencies (rare), ask the human to commit manually.' >&2
  exit 2
fi
