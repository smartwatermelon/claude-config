#!/usr/bin/env bash
# Hook: Block attempts to run merge-lock.sh or access merge-locks directory
# Prevents accidental or unauthorized merge lock operations

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# IMPORTANT: Check for dangerous commands FIRST before any early exits
# Security checks must run on the ENTIRE command string before allowing anything

# Block any command referencing the merge-locks directory
# This prevents all read/write/delete operations on lock files
if printf '%s\n' "${cmd}" | grep -qE '(^|[^a-zA-Z0-9_-])merge-locks(/|[^a-zA-Z0-9_-]|$)'; then
  printf '%s BLOCKED: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: Access to merge-locks directory is forbidden.\n' >&2
  printf '\n' >&2
  printf 'Merge locks are managed by authorized processes only.\n' >&2
  exit 2
fi

# Block dangerous merge-lock.sh script invocations regardless of method
#
# Pattern 1: Direct invocation with optional path prefix
#   ~/.claude/hooks/merge-lock.sh authorize
#   ./merge-lock.sh revoke
#   merge-lock.sh authorize (after && || ;)
#
# Pattern 2: Shell interpreter invocation
#   bash -c "merge-lock.sh authorize"
#   sh -c '~/.claude/hooks/merge-lock.sh authorize'
if printf '%s\n' "${cmd}" | grep -qE '(^|&&|\|\||;)\s*(~?[./][^[:space:]"'\'']*)?merge-lock\.sh\s+(authorize|revoke)'; then
  printf '%s BLOCKED: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: Running merge-lock.sh is forbidden.\n' >&2
  printf '\n' >&2
  printf 'Merge locks should only be managed by authorized processes.\n' >&2
  exit 2
fi

# Block shell interpreter bypass: bash -c "..." or sh -c '...'
if printf '%s\n' "${cmd}" | grep -qE '(bash|sh)\s+-c\s+.*merge-lock\.sh\s+(authorize|revoke)'; then
  printf '%s BLOCKED: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: Running merge-lock.sh is forbidden.\n' >&2
  printf '\n' >&2
  printf 'Merge locks should only be managed by authorized processes.\n' >&2
  exit 2
fi

# Allow git commit/log/show/diff commands AFTER all security checks pass
# These commands may mention merge-lock.sh or merge-locks in commit messages,
# which is safe (just text). But we must check the ENTIRE command first above.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&|\|\||;)\s*git\s+(commit|log|show|diff)\b'; then
  exit 0
fi
