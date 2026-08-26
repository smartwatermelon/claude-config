#!/usr/bin/env bash
# Hook: Block -n flag (short for --no-verify) on git commit/push
# This prevents bypassing code review via the short flag

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

# One anchored expression, not two independent greps ANDed over the whole
# string. Separate greps are satisfied by the flag appearing anywhere and a
# git verb appearing anywhere, so a commit whose MESSAGE discusses the flag
# was blocked even though it was never passed to git (claude-config#405).
#
# Requiring the flag inside the git invocation's own argument run makes it an
# argument to that command rather than unrelated text elsewhere on the line.
# The run stops at a shell operator (; & |) or a redirect, so a following
# unrelated command cannot lend its flags to a preceding git call.
#
# KNOWN GAP, unchanged here: forms that put the flag BEFORE the subcommand
# (a -C <path> invocation, or the flag directly after git) are not matched.
# Both are currently stopped by hook-check-commit-message.sh instead, which
# is incidental rather than by design. Widening detection is deliberately
# not bundled with this false-positive fix; see claude-config#405.
if printf '%s\n' "$cmd" \
  | grep -qE 'git[[:space:]]+(commit|push)([[:space:]]+[^;&|<>[:space:]]+)*[[:space:]]+-n([[:space:]]|$)'; then
  echo '🛑 BLOCKED: -n flag (short for --no-verify) is forbidden on git commit/push.' >&2
  exit 2
fi
