#!/usr/bin/env bash
# Full test suites run in CI only (Andrew, 2026-10-22). Scoped test files pass.

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "$input" | jq -r '.tool_input.command // empty')
[[ -n "${cmd}" ]] || exit 0

# One segment per line, split at ; && || | & ( and newlines; each is checked from its first word.
segments="$(printf '%s\n' "${cmd}" | sed -E 's/(&&|\|\||[;|&(){}])/\n/g')"

_lead='^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|time|exec|command|cd[[:space:]]+[^[:space:]]+)[[:space:]]+)*'
_end='[[:space:]]*$'
patterns=(
  "${_lead}((bash|sh|zsh|source|\.)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)?([^[:space:]]*/)?run-tests\.sh([[:space:]]|$)"
  "${_lead}python[0-9.]*[[:space:]]+-m[[:space:]]+unittest([[:space:]]+discover([[:space:]]|$)|${_end})"
  "${_lead}(python[0-9.]*[[:space:]]+-m[[:space:]]+)?pytest${_end}"
  "${_lead}bats[[:space:]]+(-r|--recursive)([[:space:]]|$)"
  "${_lead}bats([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^[:space:]]*/?${_end}"
  "${_lead}(npm|pnpm|yarn)([[:space:]]+run)?[[:space:]]+test${_end}"
  "${_lead}make[[:space:]]+test${_end}"
)

while IFS= read -r seg; do
  for re in "${patterns[@]}"; do
    printf '%s\n' "${seg}" | grep -qE -- "${re}" || continue
    # bats naming one file is a scoped run, not a directory.
    [[ "${re}" == *"bats([[:space:]]+-"* && "${seg}" =~ \.bats[[:space:]]*$ ]] && continue
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BLOCKED: full suite: ${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
    echo '🛑 BLOCKED: the full test suite runs in CI only, never locally.' >&2
    echo 'Run only the test files for the code you changed (Protocol 3), then push.' >&2
    echo 'CI runs the full suite as a required check.' >&2
    exit 2
  done
done <<<"${segments}"
exit 0
