#!/usr/bin/env bash
# update-tools.sh — Pull latest for all git-sourced Claude Code components
# Usage: ~/.claude/scripts/update-tools.sh
#
# Dynamically discovers all git repos under ~/.claude/ and pulls updates.
# Managed plugins (e.g. claude-plugins-official with .gcs-sha) and
# remote MCPs (Context7, Gmail, etc.) update automatically — skipped here.

set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
errors=0
updated=0
skipped=0

# Find all git repos under ~/.claude (max depth 4 to stay reasonable)
while IFS= read -r gitdir; do
  repo_path="$(dirname "$gitdir")"
  # Derive a human-readable label from the path relative to ~/.claude
  label="${repo_path#"$CLAUDE_DIR/"}"

  printf "\n=== %s ===\n" "$label"

  # Check for a remote to pull from
  if ! git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
    printf "  SKIP: no 'origin' remote\n"
    skipped=$((skipped + 1))
    continue
  fi

  remote_url=$(git -C "$repo_path" remote get-url origin)
  printf "  Remote: %s\n" "$remote_url"

  # Detect the default branch (fall back to "main")
  default_branch=$(git -C "$repo_path" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p')
  default_branch="${default_branch:-main}"

  if ! git -C "$repo_path" rev-parse --verify "$default_branch" >/dev/null 2>&1; then
    printf "  SKIP: branch '%s' not found locally\n" "$default_branch"
    errors=$((errors + 1))
    continue
  fi

  if git -C "$repo_path" pull --ff-only origin "$default_branch" 2>&1; then
    printf "  OK\n"
    updated=$((updated + 1))
  else
    printf "  FAILED (local divergence? try manual merge)\n"
    errors=$((errors + 1))
  fi
done < <(find "$CLAUDE_DIR" -maxdepth 4 -name ".git" -type d 2>/dev/null | sort)

printf "\n--- Done. %d updated, %d skipped, %d error(s). ---\n" "$updated" "$skipped" "$errors"
exit "$errors"
