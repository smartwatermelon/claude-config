#!/usr/bin/env bash
# Hook: Block -n flag (short for --no-verify) on git commit/push
# This prevents bypassing code review via the short flag

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

if printf '%s\n' "$cmd" | grep -qE '(^|[[:space:]])-n([[:space:]]|$)' \
  && printf '%s\n' "$cmd" | grep -qE 'git[[:space:]]+(commit|push)'; then
  echo '🛑 BLOCKED: -n flag (short for --no-verify) is forbidden on git commit/push.' >&2
  exit 2
fi
