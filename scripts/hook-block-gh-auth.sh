#!/usr/bin/env bash
# Blocks `gh auth` subcommands that print, switch or replace gh's keyring token (claude-wrapper#124).

# Only the typed command is checked; the gh wrapper's own `gh auth token` call never reaches tool_input.
# Called by: hook-block-all.sh

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# Command-position idiom from hook-block-api-merge.sh (#405, dotfiles#339): no match inside quoted text.
CP='(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|[`]|\$\(|\()[[:space:]]*'
ASSIGN='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GF='(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*'
GH_PATH="[\"']?[^[:space:];&|()\`\"']*/gh[\"']?"
GH_PREFIX='(command|env|exec|nohup|sudo|time|xargs)[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-/[:space:]][^[:space:]]*[[:space:]]+)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GH_INDIRECT="(${GH_PREFIX}(${GH_PATH}|gh)|${GH_PATH}|\\\\gh)"
GH_ANY="([\"']?gh[\"']?|${GH_INDIRECT})"
AUTH="${CP}${ASSIGN}${GH_ANY}[[:space:]]+${GF}auth[[:space:]]+"

joined="${cmd//$'\\\n'/ }"
# A verb ends at whitespace, end of line, or an operator, as in $(gh auth token).
END='([[:space:];&|)`]|$)'

verb=""
# Here-strings, not a pipe: pipefail then cannot turn a SIGPIPE into a skipped block.
for v in token switch login logout refresh git-credential setup-git; do
  if grep -qE "${AUTH}${v}${END}" <<<"${joined}"; then
    verb="${v}"
    break
  fi
done
# `status` is read-only unless -t/--show-token (or a cluster such as -at) prints the token.
if [[ -z "${verb}" ]] \
  && grep -qE "${AUTH}status([[:space:]][^;&|]*)?[[:space:]](-[A-Za-z]*t[A-Za-z]*|--show-token)(=|${END})" <<<"${joined}"; then
  verb="status --show-token"
fi

if [[ -n "${verb}" ]]; then
  printf '%s BLOCKED GH AUTH: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh auth %s reaches gh'"'"'s keyring credential.\n' "${verb}" >&2
  printf '\n' >&2
  printf 'This session uses restricted tokens on purpose: GH_TOKEN and the per-owner\n' >&2
  printf 'GH_TOKEN_SWM / GH_TOKEN_NOS / GH_TOKEN_TWM. The keyring token has admin:org,\n' >&2
  printf 'delete_repo and more, so it must not stand in for them.\n' >&2
  printf '\n' >&2
  printf 'If a gh call failed for a missing permission, the fix is to grant that\n' >&2
  printf 'permission on the owner'"'"'s fine-grained PAT. Only Andrew can do that, in the\n' >&2
  printf 'GitHub UI: see smartwatermelon/dev-env docs/runbooks/fleet-probe-token-scopes.md.\n' >&2
  printf 'Report the failing command and the missing permission, and ask him.\n' >&2
  printf "(\`gh auth status\` without -t is allowed.)\n" >&2
  exit 2
fi
