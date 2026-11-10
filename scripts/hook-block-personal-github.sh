#!/usr/bin/env bash
# Denies Bash commands that act on GitHub as a person, not as a GitHub App (Andrew, 2026-11-09).

# Plain gh and git push reach the dotfiles wrappers, which route them through the App.
# This hook denies the spellings that skip them.

# Not repeated here: gh auth verbs (hook-block-gh-auth.sh). No agent-context check:
# a PreToolUse hook sees only agent calls.

# arich-mac is exempt. HOOK_PERSONAL_GH_HOST replaces hostname -s for tests,
# as MACHINE_SETTINGS_HOST does.

# Best effort: a regex is not a shell parser (bash -c and aliases get past).
# Quoted text and heredocs can false-positive.

# The log names the rule, never the command: it may hold a literal token.
# Called by: hook-block-all.sh

set -euo pipefail

host="${HOOK_PERSONAL_GH_HOST:-}"
if [[ -z "${host}" ]]; then
  host="$(hostname -s 2>/dev/null)" || host=""
fi
host="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]')"
[[ "${host}" == "arich-mac" ]] && exit 0

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')
[[ -n "${cmd}" ]] || exit 0

# Command-position idiom from hook-block-api-merge.sh (#405, dotfiles#339).
CP='(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|[`]|\$\(|\()[[:space:]]*'
ASSIGN='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
# A word ends at whitespace, end of line, or an operator, as in $(gh api user).
END='([[:space:];&|)`]|$)'
# Prefixes that exec the binary, skipping the shell function. `command` takes only -p,
# so `command -v gh` passes.
PREFIX='((builtin|exec|env|nohup|sudo|time|xargs)[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-/=[:space:]][^=[:space:]]*[[:space:]]+)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*|command[[:space:]]+(-p[[:space:]]+)?)+'
path_to() {
  printf '%s' "[\"']?[^[:space:];&|()\`\"']*/${1}[\"']?"
}
GH_PATH="$(path_to gh)"
GIT_PATH="$(path_to git)"
GH_INDIRECT="(${PREFIX}([\"']?gh[\"']?|${GH_PATH})|${GH_PATH})${END}"
GIT_INDIRECT="(${PREFIX}([\"']?git[\"']?|${GIT_PATH})|${GIT_PATH})"
GIT_ANY="(\\\\?[\"']?git[\"']?|${GIT_INDIRECT})"
TOKVAR='(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GITHUB_ENTERPRISE_TOKEN)[A-Za-z0-9_]*'
DECL='((export|declare|typeset|local|readonly|env)[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-=[:space:]]+[[:space:]]+)?)*)?'
CLIENT="${CP}${ASSIGN}(${PREFIX})?([\"']?[^[:space:];&|()\`\"']*/)?(curl|wget|http|https|xh|xhs)[\"']?${END}"

joined="${cmd//$'\\\n'/ }"

# Here-strings, not pipes: pipefail then cannot turn a SIGPIPE into a skipped block.
has() { grep -qE -e "$1" <<<"${joined}"; }
has_i() { grep -qiE -e "$1" <<<"${joined}"; }

rule=""
if has "${CP}${ASSIGN}${GH_INDIRECT}"; then
  rule="gh outside the wrapper"
elif has "${CP}${ASSIGN}${GIT_INDIRECT}[[:space:]]([^;&|]*[[:space:]])?push${END}"; then
  rule="git push outside the wrapper"
elif has "${CP}${DECL}${ASSIGN}${TOKVAR}\\+?="; then
  rule="token variable assignment"
elif has "(^|[^\\\\])\\$\\{?[#!]?${TOKVAR}"; then
  rule="token variable expansion"
elif has "${CLIENT}" && has_i '([^a-z0-9-]|^)([a-z0-9-]+\.)*github\.com' \
  && has_i '(authorization|bearer|access_token=|--oauth2-bearer|(^|[[:space:]])(-u|--user|-a|--auth|--auth-type|--http-user|--http-password|--password|--netrc|--netrc-file|--netrc-optional|-n|-K|--config)([[:space:]=]|$)|(-H|--header)[[:space:]=]*["'\'']?@)'; then
  rule="HTTP client with a GitHub credential"
elif has "${CP}${DECL}${ASSIGN}GIT_(SSH|SSH_COMMAND|ASKPASS|CONFIG_[A-Z0-9_]*)=" \
  && has "(^|[[:space:]/\"'])git[\"']?[[:space:]]([^;&|]*[[:space:]])?push${END}"; then
  # git matched loosely: a quoted value (GIT_SSH_COMMAND="ssh -i k") has spaces
  # that ASSIGN cannot step over.
  rule="git push with a credential override"
else
  # git push segments: from a command-position git to the next operator.
  url_re='(git@github\.com:|ssh://([^@/[:space:]]+@)?github\.com|https?://([^/[:space:]]*@)?github\.com)'
  override_re='-c[[:space:]]*["'\'']?(credential\.|core\.sshcommand|core\.askpass|url\.|http\.[^=[:space:]]*extraheader)'
  while IFS= read -r seg; do
    [[ -n "${seg}" ]] || continue
    grep -qE "[[:space:]]push${END}" <<<"${seg}" || continue
    if grep -qiE "${url_re}" <<<"${seg}"; then
      rule="git push to a literal github.com URL"
      break
    fi
    if grep -qiE -e "${override_re}" <<<"${seg}"; then
      rule="git push with a credential override"
      break
    fi
  done < <(grep -oE "${CP}${ASSIGN}${GIT_ANY}[[:space:]][^;&|]*" <<<"${joined}" || true)
fi

if [[ -n "${rule}" ]]; then
  printf '%s BLOCKED PERSONAL GITHUB: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${rule}" >>"${HOME}/.claude/blocked-commands.log" 2>/dev/null || true
  printf "🛑 BLOCKED (%s): agents act on GitHub only as a GitHub App; use plain \`gh\`/\`git\` so the wrapper routes the call.\n" "${rule}" >&2
  exit 2
fi
