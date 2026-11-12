#!/usr/bin/env bash
# Hook: Block --no-verify flag on any command
# This enforces mandatory code review before commits

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')

# pre-commit's SKIP=<hook-id> skips any hook by id: the same bypass as
# --no-verify (#650). Unless it names only allowlisted lint hooks (below),
# block a SKIP= assignment sitting in command position
# (bare, after env/export, or after other assignments) on a line that also
# runs `git commit` or `pre-commit run`. Text inside a quoted message is not
# in command position, so it does not match. A quoted `; SKIP=x` is a known
# false positive; a regex cannot tell it from a real separator.
bt=$(printf '\140')
sq=$(printf '\047')
_aval="([^[:space:]\"${sq}]|\"[^\"]*\"|${sq}[^${sq}]*${sq})*"
_sep="(^|&&|\\|\\||;|\\||&|\\(|\\{|${bt}|[[:space:]]then|[[:space:]]do)"
_wrap="((env|export|command|sudo|!)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)*"
_skip_re="${_sep}[[:space:]]*${_wrap}([A-Za-z_][A-Za-z0-9_]*=${_aval}[[:space:]]+)*SKIP="
# Same subcommand-position shape as hook-block-main-commit.sh's commit_re.
_optval="(\"[^\"]*\"[[:space:]]+|${sq}[^${sq}]*${sq}[[:space:]]+|[^-][^|;&${bt}[:space:]]*[[:space:]]+)?"
_commit_re="${_sep}[[:space:]]*${_wrap}([A-Za-z_][A-Za-z0-9_]*=${_aval}[[:space:]]+)*(([^[:space:]|;&(){${bt}]*/)?git[[:space:]]+(-[^[:space:]]+[[:space:]]+${_optval})*commit|pre-commit[[:space:]]+run)([[:space:]]|$)"

# Lint hooks agents may SKIP= (zizmor flags existing repo findings). Never a gate.
skip_allowlist=(zizmor)

# Counts SKIP= occurrences that are not part of a longer name, quoted or not.
_count_skip() { grep -oE '(^|[^A-Za-z0-9_])SKIP=' | wc -l; }
# In one match, the shell uses the last unquoted SKIP= assignment.
_last_skip_re="(^|[[:space:];&|({${bt}])SKIP=(${_aval})\$"

# True if every SKIP= sits in a parsed command position and names only
# allowlisted literal ids. Any SKIP= the regexes cannot place blocks.
skip_is_allowlisted() {
  local matches match value id allowed found all_count parsed_count
  local -a ids
  matches=$(printf '%s\n' "$cmd" | grep -oE "${_skip_re}${_aval}") || return 1
  all_count=$(printf '%s\n' "$cmd" | _count_skip)
  parsed_count=$(printf '%s\n' "$matches" | _count_skip)
  [[ "${all_count}" -eq "${parsed_count}" ]] || return 1
  while IFS= read -r match; do
    [[ "${match}" =~ ${_last_skip_re} ]] || return 1
    value="${BASH_REMATCH[2]}"
    value="${value//\"/}"
    value="${value//${sq}/}"
    [[ -n "${value}" && "${value}" != *[\$${bt}]* ]] || return 1
    IFS=, read -ra ids <<<"${value}"
    [[ ${#ids[@]} -gt 0 ]] || return 1
    for id in "${ids[@]}"; do
      found=false
      for allowed in "${skip_allowlist[@]}"; do
        if [[ "${id}" == "${allowed}" ]]; then found=true; fi
      done
      [[ "${found}" == true ]] || return 1
    done
  done <<<"${matches}"
}

if printf '%s\n' "$cmd" | grep -qE "${_skip_re}" \
  && printf '%s\n' "$cmd" | grep -qE "${_commit_re}" \
  && ! skip_is_allowlisted; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: SKIP= on commit" >>"${HOME}/.claude/blocked-commands.log" || true
  echo '🛑 BLOCKED: SKIP= bypasses pre-commit hooks, like --no-verify. Code review is mandatory.' >&2
  echo "Agents may skip only these lint hooks: ${skip_allowlist[*]}." >&2
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
