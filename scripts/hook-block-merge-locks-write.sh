#!/usr/bin/env bash
# Hook: Block Write/Edit operations to merge-locks directory
# Prevents unauthorized modification of merge lock files

set -euo pipefail

input=$(cat)
file_path=$(printf '%s\n' "${input}" | jq -r '.tool_input.file_path // empty')

# Block any write to merge-locks directory
# Pattern catches: /merge-locks/, ./merge-locks/, ~/merge-locks/, ../merge-locks/
if printf '%s\n' "${file_path}" | grep -qE '(^|[^a-zA-Z0-9_-])merge-locks(/|[^a-zA-Z0-9_-]|$)'; then
  printf '%s BLOCKED WRITE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${file_path}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: Writing to merge-locks directory is forbidden.\n' >&2
  printf '\n' >&2
  printf 'Merge locks are managed by authorized processes only.\n' >&2
  exit 2
fi
