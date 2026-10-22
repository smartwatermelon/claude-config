#!/usr/bin/env bash
# UserPromptSubmit hook (settings.json): a prompt `approve <code>...` approves staged gate text. Always exits 0.

set -uo pipefail
unset CDPATH

# gate-review.sh needs bash 4+; macOS /bin/bash is 3.2. Same re-exec as hook-block-all.sh.
if ((BASH_VERSINFO[0] < 4)); then
  for candidate in /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "${candidate}" ]]; then
      PATH="${candidate%/*}:${PATH}" exec "${candidate}" "$0" "$@"
    fi
  done
  exit 0
fi

_self="${BASH_SOURCE[0]}"
if [[ -L "${_self}" ]]; then
  _target="$(readlink "${_self}")"
  [[ "${_target}" == /* ]] || _target="$(dirname "${_self}")/${_target}"
  _self="${_target}"
fi
GATE="$(cd "$(dirname "${_self}")" && pwd)/gate-review.sh"
unset _self _target

_say() {
  jq -n --arg m "$1" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'
  exit 0
}

input="$(cat)"
prompt="$(printf '%s' "${input}" | jq -r '.prompt // empty' 2>/dev/null)" || exit 0
# Leading blank lines and spaces are ignored; the match is case-insensitive.
prompt="${prompt#"${prompt%%[![:space:]]*}"}"
prompt="${prompt,,}"
re='^approve[[:space:]]+([0-9a-f]{6}([[:space:],]+[0-9a-f]{6})*)([^0-9a-z]|$)'
[[ "${prompt}" =~ ${re} ]] || exit 0

list="${BASH_REMATCH[1]//[,$'\n\t\r']/ }"
read -ra codes <<<"${list}"
((${#codes[@]} > 0)) || exit 0

out="$("${GATE}" approve-hash "${codes[@]}" 2>&1)"
rc=$?
if ((rc == 0)); then
  _say "gate: approved ${#codes[@]} item(s) by code (${codes[*]}).
${out}"
fi
_say "gate: nothing approved for ${codes[*]}.
${out}"
