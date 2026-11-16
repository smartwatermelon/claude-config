#!/usr/bin/env bash
# Hook: Gate the EnterWorktree built-in tool; raw git makes every worktree

# Name form: denied. Path form: allowed only for a linked worktree at
# <repo>/.claude/worktrees/<slug>.

#   Agent `isolation: "worktree"` never calls this tool, so is unaffected.
#
#   Fail-closed: every deny exits 2, unparseable input too (#796).
#
# Called by: machine-settings/base.json PreToolUse matcher "EnterWorktree"

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

log_block() {
  printf '%s BLOCKED ENTER_WORKTREE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${input}" \
    >>"${HOME}/.claude/blocked-commands.log" 2>/dev/null || true
}

deny_path() {
  log_block
  printf '🛑 BLOCKED: %s\n\n' "${1}" >&2
  printf 'EnterWorktree path enters only a worktree raw git made:\n' >&2
  printf '  an absolute path to <repo>/.claude/worktrees/<slug>, linked to that repo.\n' >&2
  exit 2
}

# path form: allow only a real linked worktree of the repo that holds it.
if [[ -z "${parse_failed}" && -n "${path}" ]]; then
  [[ -z "${name}" ]] || deny_path "EnterWorktree takes name or path, not both"
  [[ "${path}" == /* ]] || deny_path "EnterWorktree path must be absolute (got: ${path})"
  [[ "/${path}/" != */../* ]] || deny_path "EnterWorktree path must not contain '..' (got: ${path})"
  resolved=$(cd -P -- "${path}" 2>/dev/null && pwd -P) ||
    deny_path "EnterWorktree path does not exist (got: ${path})"
  slug_re='^(/.+)/\.claude/worktrees/[A-Za-z0-9_][A-Za-z0-9._-]{0,99}$'
  [[ "${resolved}" =~ ${slug_re} ]] ||
    deny_path "EnterWorktree path is not <repo>/.claude/worktrees/<slug> (resolves to: ${resolved})"
  owner="${BASH_REMATCH[1]}"
  [[ -f "${resolved}/.git" ]] ||
    deny_path "EnterWorktree path is not a linked worktree (no .git file in ${resolved})"
  top=$(git -C "${resolved}" rev-parse --show-toplevel 2>/dev/null) || top=""
  common=$(git -C "${resolved}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  owner_real=$(cd -P -- "${owner}" 2>/dev/null && pwd -P) || owner_real=""
  [[ -n "${top}" && "${top}" == "${resolved}" ]] ||
    deny_path "EnterWorktree path is not the top of a git worktree (${resolved})"
  [[ -n "${owner_real}" && "${common}" == "${owner_real}/.git" ]] ||
    deny_path "EnterWorktree path is not a worktree of ${owner} (its git dir is ${common:-unknown})"
  exit 0
fi

log_block

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

printf '🛑 BLOCKED: EnterWorktree does not make worktrees here; make it with raw git:\n' >&2
printf '  git -C %s worktree add --no-track -b claude/<type>-<desc>-<session-id> .claude/worktrees/%s origin/main\n' \
  "${repo}" "${wt_name}" >&2
printf '  git -C %s/.claude/worktrees/%s rev-parse --show-toplevel\n' "${repo}" "${wt_name}" >&2
printf 'then you may enter it with EnterWorktree path=<that worktree>.\n' >&2
printf 'Push with: git -C <worktree> push origin <branch> (no -u); gh pr create --head <branch>\n' >&2
exit 2
