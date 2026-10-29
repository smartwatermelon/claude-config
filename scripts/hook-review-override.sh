#!/usr/bin/env bash
# UserPromptSubmit hook: a prompt `override <code>...` lets one blocked review through. Always exits 0.

set -uo pipefail
unset CDPATH

# ${var,,} needs bash 4+; macOS /bin/bash is 3.2. Same re-exec as hook-gate-inline-approve.sh.
if ((BASH_VERSINFO[0] < 4)); then
  for candidate in /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "${candidate}" ]]; then
      PATH="${candidate%/*}:${PATH}" exec "${candidate}" "$0" "$@"
    fi
  done
  exit 0
fi

STATE_DIR="${REVIEW_STATE_DIR:-${HOME}/.local/state/claude-review}"
PENDING="${STATE_DIR}/review-overrides/pending"
# Env override is safe here: the harness env is not the agent's. KNOWN LIMITATION: a forcing function, not a lock.
APPROVED="${REVIEW_OVERRIDE_DIR:-${HOME}/.claude/gate-review/review-overrides}"
APPROVAL_TTL="${REVIEW_OVERRIDE_TTL:-1800}"
PENDING_TTL="${REVIEW_OVERRIDE_PENDING_TTL:-86400}"
RM_BIN="${REVIEW_RM_BIN:-rm}"
MV_BIN="${REVIEW_MV_BIN:-mv}"

_say() {
  jq -n --arg m "$1" \
    '{systemMessage: $m, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $m}}'
  exit 0
}

# _field <file> <key>: the value of one key=value line.
_field() {
  awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1" 2>/dev/null || true
}

input="$(cat)"
prompt="$(printf '%s' "${input}" | jq -r '.prompt // empty' 2>/dev/null)" || exit 0
# Leading blank lines and spaces are ignored; the match is case-insensitive.
prompt="${prompt#"${prompt%%[![:space:]]*}"}"
prompt="${prompt,,}"
re='^override[[:space:]]+([0-9a-f]{6}([[:space:],]+[0-9a-f]{6})*)([^0-9a-z]|$)'
[[ "${prompt}" =~ ${re} ]] || exit 0

list="${BASH_REMATCH[1]//[,$'\n\t\r']/ }"
read -ra codes <<<"${list}"
((${#codes[@]} > 0)) || exit 0

# A mistyped extra code (hex, or letters with a digit) must not let the others through.
rest="${prompt:${#BASH_REMATCH[0]}-${#BASH_REMATCH[3]}}"
rest="${rest#"${rest%%[![:space:],]*}"}"
next="${rest%%[^0-9a-z]*}"
if [[ "${next}" =~ ^[0-9a-f]+$ || "${next}" =~ [0-9] ]]; then
  _say "review override: nothing approved: '${next}' after the codes is not a 6-character code."
fi
# A code-shaped word anywhere later ("abc123 - def456") means the list was mistyped.
read -ra later <<<"${rest//[^0-9a-z]/ }"
for w in "${later[@]}"; do
  [[ "${w}" =~ ^[0-9a-f]{6}$ ]] && _say "review override: nothing approved: '${w}' is not separated from the codes by a space or comma."
done

now="$(date +%s)"

# Unused approvals expire after APPROVAL_TTL. run-review.sh cannot delete here (sandbox), so this hook prunes.
for f in "${APPROVED}"/*; do
  [[ -f "${f}" ]] || continue
  at="$(_field "${f}" approved)"
  [[ "${at}" =~ ^[0-9]+$ ]] && ((now - at <= APPROVAL_TTL)) && continue
  "${RM_BIN}" -f "${f}" 2>/dev/null || true
done

# All or nothing: every code must name one live pending record whose mode and hash still give that code.
for code in "${codes[@]}"; do
  f="${PENDING}/${code}"
  [[ -f "${f}" ]] || _say "review override: nothing approved: no blocked review has code ${code}."
  created="$(_field "${f}" created)"
  if ! [[ "${created}" =~ ^[0-9]+$ ]] || ((now - created > PENDING_TTL)); then
    _say "review override: nothing approved: the block with code ${code} has expired; retry to get a new code."
  fi
  mode="$(_field "${f}" mode)"
  hash="$(_field "${f}" diff_hash)"
  [[ "${mode}" == "commit" || "${mode}" == "full-diff" ]] && [[ "${hash}" =~ ^[0-9a-f]{64}$ ]] \
    || _say "review override: nothing approved: the record for ${code} is not well formed."
  want="$(printf '%s\n%s\n' "${mode}" "${hash}" | shasum -a 256 | cut -c1-6)" || want=""
  [[ "${want}" == "${code}" ]] || _say "review override: nothing approved: the record for ${code} does not match its code."
done

mkdir -p "${APPROVED}" 2>/dev/null || _say "review override: nothing approved: cannot create ${APPROVED}."
# Two phases, so a failed write approves nothing: every temp file first, then every move; a failure undoes the moves.
for code in "${codes[@]}"; do
  if ! { grep -v '^approved=' "${PENDING}/${code}"; printf 'approved=%s\n' "${now}"; } >"${APPROVED}/.${code}.tmp" 2>/dev/null; then
    for c in "${codes[@]}"; do "${RM_BIN}" -f "${APPROVED}/.${c}.tmp" 2>/dev/null || true; done
    _say "review override: nothing approved: could not write the approval for ${code}."
  fi
done
moved=()
for code in "${codes[@]}"; do
  if ! "${MV_BIN}" -f "${APPROVED}/.${code}.tmp" "${APPROVED}/${code}" 2>/dev/null; then
    for c in "${moved[@]}"; do "${RM_BIN}" -f "${APPROVED}/${c}" 2>/dev/null || true; done
    for c in "${codes[@]}"; do "${RM_BIN}" -f "${APPROVED}/.${c}.tmp" 2>/dev/null || true; done
    _say "review override: nothing approved: could not move the approval for ${code}; rolled back ${moved[*]:-none}."
  fi
  moved+=("${code}")
done
summary=""
for code in "${codes[@]}"; do
  "${RM_BIN}" -f "${PENDING}/${code}" 2>/dev/null || true
  a="${APPROVED}/${code}"
  mode="$(_field "${a}" mode)"
  repo="$(_field "${a}" repo)"
  branch="$(_field "${a}" branch)"
  why="$(_field "${a}" summary)"
  summary+="
  ${code}: ${mode} in ${repo} (${branch}): ${why}"
done
_say "review override: approved ${codes[*]}. The next review of each exact diff passes once, within $((APPROVAL_TTL / 60)) minutes.${summary}"
