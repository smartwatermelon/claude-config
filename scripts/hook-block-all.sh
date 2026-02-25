#!/usr/bin/env bash
# Hook: Wrapper that runs all block hooks
# Keeps settings.json clean by consolidating block checks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read input once and pass to each hook
input=$(cat)

for hook in \
  "$SCRIPT_DIR/hook-block-no-verify.sh" \
  "$SCRIPT_DIR/hook-block-short-no-verify.sh" \
  "$SCRIPT_DIR/hook-block-main-commit.sh" \
  "$SCRIPT_DIR/hook-block-merge-lock-authorize.sh" \
  "$SCRIPT_DIR/hook-block-api-merge.sh"; do
  if [[ -x "$hook" ]]; then
    printf '%s\n' "$input" | "$hook" || exit $?
  fi
done
