#!/usr/bin/env bash
# Names red default branches from the dev-env digest (dev-env#229 D, #262).
# Red: notice. None: silent. Unreadable: "unknown", never silent.
set -uo pipefail

gh_bin="${RED_MAIN_GH_BIN:-gh}"
issue_repo="${RED_MAIN_REPO:-smartwatermelon/dev-env}"
cache_minutes="${RED_MAIN_CACHE_MINUTES:-30}"
[[ "${cache_minutes}" =~ ^[0-9]+$ ]] || cache_minutes=30
now="${RED_MAIN_NOW:-$(date +%s)}"
cache="${HOME}/.local/state/claude-config/red-main.cache"

emit() { # emit <text>: stdout for the model, stderr for the human
  printf '%s\n' "$1"
  printf '⚠️  %s\n' "$1" >&2
}

# Cache: line 1 is the epoch it was written, the rest is the notice (may be empty).
if [[ -f "${cache}" ]]; then
  cached_at=""
  { read -r cached_at <"${cache}"; } 2>/dev/null || true
  if [[ "${cached_at}" =~ ^[0-9]+$ ]] && ((now - cached_at >= 0 && now - cached_at < cache_minutes * 60)); then
    notice="$(tail -n +2 "${cache}" 2>/dev/null || true)"
    [[ -n "${notice}" ]] && emit "${notice}"
    exit 0
  fi
fi

# Bound the network read: a session must not hang on a slow API.
timeout_bin="${RED_MAIN_TIMEOUT_BIN:-$(command -v gtimeout || command -v timeout || true)}"
bound=()
[[ -n "${timeout_bin}" ]] && bound=("${timeout_bin}" 8)

# List open issues and match the marker in the body. Not --search: GitHub's
# index tokenizes "<!--" away (dev-env upsert-issue.sh).
issues=""
if ! issues="$("${bound[@]}" "${gh_bin}" issue list -R "${issue_repo}" --state open --limit 200 \
  --json url,body,updatedAt 2>/dev/null)"; then
  issues=""
fi

notice=""
if [[ -z "${issues}" ]]; then
  notice="Red default branch status unknown: could not read open issues in ${issue_repo} (gh failed or timed out)."
else
  digest="$(jq -c '[.[] | select(.body | contains("<!-- dependabot-digest:v1 -->"))] | first // empty' \
    <<<"${issues}" 2>/dev/null || true)"
  if [[ -z "${digest}" ]]; then
    notice="Red default branch status unknown: no open Dependabot digest issue in ${issue_repo}."
  else
    line="$(jq -r '.body' <<<"${digest}" | grep -m1 -oE '<!-- dependabot-digest:main-red:[^>]*-->' || true)"
    if [[ -z "${line}" ]]; then
      notice="Red default branch status unknown: the digest has no main-red line yet (it gains one on its next run)."
    else
      list="${line#<!-- dependabot-digest:main-red:}"
      list="${list%-->}"
      # Keep only owner/repo tokens: the issue body is text the model will read.
      repos=()
      for r in ${list}; do
        [[ "${r}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] && repos+=("${r}")
      done
      if ((${#repos[@]} > 0)); then
        url="$(jq -r '.url' <<<"${digest}")"
        updated="$(jq -r '.updatedAt' <<<"${digest}")"
        epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${updated}" +%s 2>/dev/null || true)"
        [[ -n "${epoch}" ]] && updated="$(date -r "${epoch}" '+%Y-%m-%d %H:%M %Z')"
        notice="RED DEFAULT BRANCH: ${repos[*]}. Fix these before other work (dev-env#229, decision D):"
        notice+=" a red default branch blocks every Dependabot PR there, security fixes included."
        notice+=" Source: ${url}, updated ${updated}."
      fi
    fi
  fi
fi

# Cache only a definite answer; an unknown retries on the next start.
if [[ "${notice}" != "Red default branch status unknown"* ]]; then
  mkdir -p "${cache%/*}" 2>/dev/null &&
    printf '%s\n%s' "${now}" "${notice}" >"${cache}" 2>/dev/null
fi
[[ -n "${notice}" ]] && emit "${notice}"
exit 0
