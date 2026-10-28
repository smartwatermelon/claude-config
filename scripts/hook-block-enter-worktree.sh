#!/usr/bin/env bash
# Hook: Deny the EnterWorktree built-in tool and steer to raw git
#
# Purpose:
#   Raw git is the one worktree method (2026-10-27). Deny every EnterWorktree
#   call and print the raw command, filled in where known.

#   Agent `isolation: "worktree"` never calls this tool, so is unaffected.

#   Fail-closed: every path exits 2, unparseable input too (#796).
#
# Called by: settings.json PreToolUse matcher "EnterWorktree"

set -euo pipefail

input=$(cat) || input=""

name=""
path=""
cwd=""
parse_failed=""
name=$(printf '%s\n' "${input}" | jq -r '.tool_input.name // empty' 2>/dev/null) || parse_failed=1
if [[ -z "${parse_failed}" ]]; then
  path=$(printf '%s\n' "${input}" | jq -r '.tool_input.path // empty' 2>/dev/null) || parse_failed=1
  cwd=$(printf '%s\n' "${input}" | jq -r '.cwd // empty' 2>/dev/null) || parse_failed=1
fi

printf '%s BLOCKED ENTER_WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${input}" \
  >>"${HOME}/.claude/blocked-commands.log" 2>/dev/null || true

# Resolve the primary checkout that owns cwd. --git-common-dir is the main
# repo's .git even from inside a linked worktree.
repo="<repo>"
if [[ -n "${cwd}" && -d "${cwd}" ]]; then
  common_dir=$(git -C "${cwd}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=""
  if [[ "${common_dir}" == /*/.git ]]; then
    repo="${common_dir%/.git}"
  fi
fi

# Only a plain slug is filled in; anything else stays a placeholder.
wt_name="<name>"
if [[ "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$ ]]; then
  wt_name="${name}"
fi

if [[ -n "${parse_failed}" ]]; then
  printf '🛑 BLOCKED: EnterWorktree hook input could not be parsed\n\n' >&2
fi

if [[ -z "${parse_failed}" && -n "${path}" ]]; then
  printf '🛑 BLOCKED: EnterWorktree is not used here.\n\n' >&2
  printf 'That worktree already exists: %s\n' "${path}" >&2
  printf 'Keep working in it by absolute path; no tool is needed:\n' >&2
  printf '  git -C %s rev-parse --show-toplevel\n' "${path}" >&2
  printf '  then git -C <worktree> ..., and Edit/Write with full paths.\n' >&2
  exit 2
fi

printf '🛑 BLOCKED: EnterWorktree is not used here; make the worktree with raw git instead:\n' >&2
printf '  git -C %s worktree add --no-track -b claude/<type>-<desc>-<session-id> .claude/worktrees/%s origin/main\n' \
  "${repo}" "${wt_name}" >&2
printf '  git -C %s/.claude/worktrees/%s rev-parse --show-toplevel\n' "${repo}" "${wt_name}" >&2
printf 'then work with absolute paths (git -C <worktree>, Edit with full paths).\n' >&2
printf 'Push with: git -C <worktree> push origin <branch> (no -u); gh pr create --head <branch>\n' >&2
exit 2
