#!/usr/bin/env bash
# Hook: Block --no-verify flag on any command
# This enforces mandatory code review before commits

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

# pre-commit's SKIP=<hook-id> skips any hook by id: the same bypass as
# --no-verify (#650). Block a SKIP= assignment sitting in command position
# (bare, after env/export, or after other assignments) on a line that also
# runs `git commit` or `pre-commit run`. Text inside a quoted message is not
# in command position, so it does not match. A quoted `; SKIP=x` is a known
# false positive; a regex cannot tell it from a real separator.
bt=$(printf '\140')
sq=$(printf '\047')
_aval="([^[:space:]\"${sq}]|\"[^\"]*\"|${sq}[^${sq}]*${sq})*"
_sep="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|[[:space:]]then|[[:space:]]do)"
_wrap="((env|export|command|sudo)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)*"
_skip_re="${_sep}[[:space:]]*${_wrap}([A-Za-z_][A-Za-z0-9_]*=${_aval}[[:space:]]+)*SKIP="
# Same subcommand-position shape as hook-block-main-commit.sh's commit_re.
_optval="(\"[^\"]*\"[[:space:]]+|${sq}[^${sq}]*${sq}[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"
_commit_re="${_sep}[[:space:]]*${_wrap}([A-Za-z_][A-Za-z0-9_]*=${_aval}[[:space:]]+)*(([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit|pre-commit[[:space:]]+run)([[:space:]]|$)"

if printf '%s\n' "$cmd" | grep -qE "${_skip_re}" \
  && printf '%s\n' "$cmd" | grep -qE "${_commit_re}"; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: SKIP= on commit" >>"${HOME}/.claude/blocked-commands.log" || true
  echo '🛑 BLOCKED: SKIP= bypasses pre-commit hooks, like --no-verify. Code review is mandatory.' >&2
  echo '' >&2
  echo 'For genuine emergencies (rare), ask the human to commit manually with SKIP=<hook-id>.' >&2
  exit 2
fi

if printf '%s\n' "$cmd" | grep -qE '(^|[[:space:]])--no-verify([[:space:]]|$)'; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: $cmd" >>"${HOME}/.claude/blocked-commands.log" || true
  echo '🛑 BLOCKED: --no-verify is forbidden. Code review is mandatory.' >&2
  echo '' >&2
  echo 'The review hooks exist to catch bugs before CI. Skipping them wastes money.' >&2
  echo '' >&2
  echo 'If review times out, retry or fix the timeout:' >&2
  echo '  git config review.timeout 300' >&2
  echo '' >&2
  echo 'For genuine emergencies (rare), ask the human to commit manually.' >&2
  exit 2
fi
