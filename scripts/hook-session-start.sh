#!/usr/bin/env bash
# Hook: SessionStart - Run project-specific setup hooks if present

set -euo pipefail

input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd // empty')

if [[ -n "$cwd" ]] && [[ -f "$cwd/.claude/hooks/setup-plaid-token.sh" ]]; then
  cd "$cwd" && ./.claude/hooks/setup-plaid-token.sh
fi
