#!/usr/bin/env bash
# Hook: Block Bash execution of "merge-lock.sh authorize"
# Merge authorization is a human-only action.
#
# The Write/Edit hooks already block direct file writes to merge-locks/.
# This hook blocks the higher-level authorization command via the Bash tool.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

if printf '%s\n' "$cmd" | grep -qE 'merge-lock\.sh[[:space:]]+(authorize|auth)([[:space:]]|$)'; then
  printf '%s BLOCKED MERGE-LOCK AUTHORIZE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "$cmd" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: merge-lock.sh authorize is a human-only action.\n' >&2
  printf '\n' >&2
  printf 'Merge authorization must be granted by the human, not Claude.\n' >&2
  printf 'Ask the human to run: ~/.claude/hooks/merge-lock.sh authorize <PR> "<reason>"\n' >&2
  exit 2
fi
