#!/usr/bin/env bash
# StatusLine: Display git branch/status and live context-window pressure.
#
# The context segment exists because a session can compact every few minutes
# without the cause being visible. On 2026-09-03 an infra session compacted
# three times in under three hours: the warm-start floor had grown 45k -> 89k
# against a 200k autoCompactWindow, mostly from an 890-tool MCP connector
# listing re-injected at every restart. Nothing surfaced that until /context
# was run by hand, after the fact. Showing the number continuously turns a
# post-mortem into something noticed while it happens.
#
# MCP tool counts are deliberately NOT shown: the statusLine stdin schema
# exposes no MCP server or tool inventory, and a count derived from anywhere
# else would be a guess. Context percentage is the signal that actually
# matters, and it is reported directly.
#
# Portability: this script is shared across machines and Claude accounts via
# the claude-config repo, so it must not assume a username, home path, or any
# particular set of loaded tools. Every field it reads is optional — older CLI
# builds omit context_window and prompt_cache, and jq is 1.7 on some hosts and
# 1.8 on others. Absent fields degrade to a shorter status line, never to an
# error.

input=$(cat)

# `// empty` on every lookup: a missing key must yield an empty string rather
# than the literal "null", so the guards below can test with -n.
current_dir=$(printf '%s' "${input}" | jq -r '.workspace.current_dir // empty' 2>/dev/null)

# Fall back to the top-level cwd, then to $PWD, so a schema change or an older
# build still produces a usable path segment.
if [[ -z "${current_dir}" ]]; then
  current_dir=$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)
fi
[[ -n "${current_dir}" ]] || current_dir="${PWD}"

cd "${current_dir}" 2>/dev/null || true

# Split the pipeline so a git failure surfaces as an empty string rather than
# being masked by sed's exit status (SC2312).
git_branch_raw=$(git branch 2>/dev/null || true)
git_branch=$(printf '%s' "${git_branch_raw}" | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/')
git_status=$(git status --porcelain 2>/dev/null || true)

indicators=""
if echo "${git_status}" | grep -q "^ M"; then
  indicators+="*"
fi
if echo "${git_status}" | grep -q "^M"; then
  indicators+="+"
fi
if echo "${git_status}" | grep -q "??"; then
  indicators+="?"
fi

if [[ -n "${indicators}" ]]; then
  git_status=" [${indicators}]"
else
  git_status=""
fi

# --- context window -------------------------------------------------------
# used_percentage is pre-calculated by the harness; prefer it over dividing
# total_input_tokens by context_window_size ourselves. Deriving it locally
# would re-introduce exactly the chars-per-token style estimation error this
# segment is meant to replace.
ctx_used_pct=$(printf '%s' "${input}" |
  jq -r '.context_window.used_percentage // empty' 2>/dev/null)
ctx_tokens=$(printf '%s' "${input}" |
  jq -r '.context_window.total_input_tokens // empty' 2>/dev/null)
ctx_size=$(printf '%s' "${input}" |
  jq -r '.context_window.context_window_size // empty' 2>/dev/null)

context_segment=""
if [[ -n "${ctx_tokens}" ]]; then
  # Render tokens as a compact "27k" rather than 26903: the exact figure moves
  # every turn and the magnitude is what a human acts on.
  ctx_k=$(awk -v t="${ctx_tokens}" 'BEGIN { printf "%.0f", t / 1000 }')

  pct_text=""
  if [[ -n "${ctx_used_pct}" ]]; then
    pct_text=$(awk -v p="${ctx_used_pct}" 'BEGIN { printf " %.0f%%", p }')
  fi

  # Render a 1M window as "1M" rather than "1000k" — the extended-context
  # window is the case where the distinction is most worth reading at a glance.
  size_text=""
  if [[ -n "${ctx_size}" ]]; then
    size_text=$(awk -v s="${ctx_size}" 'BEGIN {
      if (s >= 1000000) { printf "/%gM", s / 1000000 }
      else { printf "/%.0fk", s / 1000 }
    }')
  fi

  # Colour by pressure so the line is scannable without reading digits.
  # Thresholds track the autocompact buffer: compaction fires near 80%, so
  # amber at 60 gives warning while there is still room to act.
  ctx_color=$'\033[32m' # green
  if [[ -n "${ctx_used_pct}" ]]; then
    # %.0f, not %d: %d truncates, so 74.6% would display as "75%" while
    # comparing as 74 and staying green -- the colour would contradict the
    # number it sits next to. Round so the threshold matches what is shown.
    pressure=$(awk -v p="${ctx_used_pct}" 'BEGIN { printf "%.0f", p }')
    if ((pressure >= 75)); then
      ctx_color=$'\033[31m' # red
    elif ((pressure >= 60)); then
      ctx_color=$'\033[33m' # amber
    fi
  fi

  context_segment=$(printf ' %sctx %sk%s%s\033[0m' \
    "${ctx_color}" "${ctx_k}" "${size_text}" "${pct_text}")
fi

# --- prompt cache ---------------------------------------------------------
# A cold cache after a compaction is the expensive moment: the whole floor is
# re-written at the cache-creation rate. Flagging it explains an otherwise
# mysterious cost spike. Field added in CLI 2.1.251; absent on older builds.
cache_segment=""
# NOT `.warm // empty`: jq's alternative operator treats `false` as empty, so
# the one value this check exists to catch would be swallowed. Test for the
# key's presence instead, then read it.
cache_warm=$(printf '%s' "${input}" |
  jq -r 'if has("prompt_cache") and (.prompt_cache | has("warm"))
         then (.prompt_cache.warm | tostring) else empty end' 2>/dev/null)
if [[ "${cache_warm}" == "false" ]]; then
  cache_segment=$'\033[33m cold\033[0m'
fi

user_name=$(whoami || true)
host_name=$(hostname -s || true)

printf "\033[32m%s@%s\033[0m:\033[34m%s\033[31m%s%s\033[0m%s%s" \
  "${user_name}" \
  "${host_name}" \
  "${current_dir/#"${HOME}"/"~"}" \
  "${git_branch}" \
  "${git_status}" \
  "${context_segment}" \
  "${cache_segment}"
