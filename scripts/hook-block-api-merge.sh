#!/usr/bin/env bash
# Hook: Block direct REST API calls to the GitHub PR merge endpoint
#
# Purpose:
#   The gh() wrapper in ~/.config/bash/functions.sh intercepts `gh pr merge`
#   and routes it through pre-merge-review.sh + merge-lock authorization.
#   However, `gh api .../pulls/NNN/merge --method PUT` bypasses the wrapper
#   entirely, circumventing all code quality gates.
#
#   This hook closes that gap by blocking the merge endpoint at the Claude
#   Code PreToolUse layer, before any Bash command is executed.
#
# Root cause documented in post-mortems:
#   - PR #813: gh pr merge failed silently → gh api used as workaround
#   - v1.11.0: pattern reused → 9-second unauthorized production merge
#
# If gh pr merge fails: report the failure, ask the human to merge manually.
# NEVER use gh api .../merge as a workaround.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Block: gh api .../pulls/{number}/merge  (REST endpoint)
# Suffix boundary ([[:space:]]|$|[^[:alnum:]_]) prevents false positives on
# hypothetical paths like pulls/NNN/merge_status while still matching:
#   gh api repos/owner/repo/pulls/123/merge --method PUT
#   gh api /repos/owner/repo/pulls/123/merge
#   gh api "repos/owner/repo/pulls/123/merge"
#   echo x && gh api repos/o/r/pulls/1/merge --method PUT
if printf '%s\n' "${cmd}" | grep -qE 'gh[[:space:]]+api[[:space:]].*pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
  printf '%s BLOCKED API MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: Direct REST API PR merge bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf 'This endpoint skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf 'Use `gh pr merge <number>` instead — it routes through pre-merge-review.sh.\n' >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use the REST API as a workaround.\n' >&2
  exit 2
fi

# Block: gh api graphql with mergePullRequest mutation
# GraphQL offers the same merge capability as the REST endpoint above.
# Covers inline mutations passed via -f query=... or --field query=...
# Known gap: --input <file> with the mutation inside the file is not caught here;
# that gap is documented in Protocol 6 in CLAUDE.md.
if printf '%s\n' "${cmd}" | grep -qE 'gh[[:space:]]+api[[:space:]].*graphql.*mergePullRequest'; then
  printf '%s BLOCKED GRAPHQL MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: GraphQL mergePullRequest mutation bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf 'Use `gh pr merge <number>` instead — it routes through pre-merge-review.sh.\n' >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh [global-flags] pr merge (global-flag prefix bypass)
# When global flags like -R/--repo appear before the subcommand, the gh() bash
# wrapper's positional check ($1=='pr' && $2=='merge') is skipped entirely,
# allowing a merge without pre-merge review or merge-lock authorization.
#
# The leading (^|[;|&][[:space:]]*) anchor requires 'gh' to appear at the start
# of a line or after a shell operator (;, |, &, &&), so 'gh -R' text embedded
# in commit messages or quoted strings does not produce false positives.
if printf '%s\n' "${cmd}" | grep -qE '(^|[;|&][[:space:]]*)gh[[:space:]]+-[^[:space:]].*[[:space:]]pr[[:space:]]+merge([[:space:]]|$)'; then
  printf '%s BLOCKED GLOBAL FLAG MERGE BYPASS: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log"
  printf '🛑 BLOCKED: gh pr merge with global flags (e.g. -R repo) bypasses shell wrapper routing.\n' >&2
  printf '\n' >&2
  printf 'Placing global flags before the subcommand skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf 'Use `gh pr merge <number>` (no global flags before the subcommand) instead.\n' >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use global flag placement as a workaround.\n' >&2
  exit 2
fi
