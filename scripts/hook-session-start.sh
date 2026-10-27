#!/usr/bin/env bash
# Hook: SessionStart - surfaces the pending-issues fallback queue
#
# Project-specific setup hooks can be configured in each project's
# .claude/hooks/ directory and invoked via the claude-wrapper's
# pre-launch hook mechanism (see ~/.local/bin/claude-wrapper).
#
# ~/.local/state/claude-review/pending-issues/ is where lib-review-issues.sh writes a finding it
# could not file as a GitHub issue (gh stubbed during a dry-run, auth failure,
# rate limit, Issues disabled on the target repo). That fallback is correct —
# the finding survives instead of being lost — but nothing ever read the
# directory back. It reached 47 files spanning 2026-06-10 to 2026-08-24 before
# anyone looked, and one finding sat there for 11 days while the problem it
# described grew (smartwatermelon/dotfiles#231, #227).
#
# Printing the count at session start is the cheap half of the fix: a
# write-only queue becomes a queue someone sees. The other half is
# _write_pending_issue_file recording REPO_OWNER/REPO_NAME, so a drain knows
# where each finding belongs.

# Consume stdin (required by hook protocol)
cat >/dev/null

# Queue left ~/.claude (sandbox). Old dir still read for findings queued earlier.
if [[ -n "${PENDING_ISSUES_DIR:-}" ]]; then
  PENDING_DIRS=("${PENDING_ISSUES_DIR}")
else
  PENDING_DIRS=("${REVIEW_STATE_DIR:-${HOME}/.local/state/claude-review}/pending-issues" "${HOME}/.claude/pending-issues")
fi

for PENDING_DIR in "${PENDING_DIRS[@]}"; do
  # A missing directory is the normal case on a fresh machine, not an error.
  [[ -d "${PENDING_DIR}" ]] || continue

  # find, not a glob: an empty dir's glob counts as one file. `|| true`: 0 on error.
  pending_count=$(
    { find "${PENDING_DIR}" -maxdepth 1 -name '*.md' -type f -print 2>/dev/null || true; } \
      | { wc -l || true; } \
      | { tr -d ' ' || true; }
  )

  [[ "${pending_count}" -gt 0 ]] || continue

  # stderr, not stdout: stdout is the hook protocol's channel back to the
  # harness, and this is a human-facing notice rather than hook output.
  printf '⚠️  %s unfiled review finding(s) in %s\n' "${pending_count}" "${PENDING_DIR}" >&2
  printf '   These are findings the reviewer could not file as GitHub issues.\n' >&2
  printf '   Each records its target repo in its Repo header line; drain them by filing\n' >&2
  printf '   each in that repo, then deleting the file.\n' >&2
done

# Dev mode (#453): stdout so the model knows which hooks run; stderr for the human. Same paths as install.sh.
deploy_clone="${HOME}/.local/share/claude-config"
if [[ -e "${deploy_clone}/.git" ]]; then
  hook_link="$(readlink "${HOME}/.claude/hooks/run-review.sh" 2>/dev/null || true)"
  if [[ "${hook_link}" != "${deploy_clone}/"* ]]; then
    dev_path="${hook_link%/hooks/run-review.sh}"
    dev_since=""
    marker="${HOME}/.local/state/claude-config/dev-mode"
    if [[ -f "${marker}" ]]; then
      dev_since="$(sed -n 's/^since=//p' "${marker}" 2>/dev/null || true)"
    fi
    if [[ "${dev_since}" =~ ^[0-9]+$ ]]; then
      dev_since=" since $(date -r "${dev_since}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "${dev_since}")"
    else
      dev_since=""
    fi
    notice="claude-config DEV MODE${dev_since}: ~/.claude hooks run from ${dev_path:-nowhere (no link)}, not ${deploy_clone}."
    notice+=" Run claude-config-deploy in a terminal to return to origin/main."
    printf '%s\n' "${notice}"
    printf '⚠️  %s\n' "${notice}" >&2
  fi

  # Deploy health (#453): a refusal notifies once; a dead agent writes nothing. A problem beats stale. As status-line.sh.
  deploy_state="${HOME}/.local/state/claude-config"
  deploy_log="${deploy_state}/deploy.log"
  deploy_notice=""
  if [[ -f "${deploy_state}/deploy.problem" ]]; then
    problem_key=""
    { read -r problem_key <"${deploy_state}/deploy.problem"; } 2>/dev/null || true
    problem_key="${problem_key//[^A-Za-z0-9._-]/}"
    problem_key="${problem_key:0:24}"
    deploy_notice="claude-config DEPLOY PROBLEM (${problem_key:-unknown}): the last deploy run refused or failed,"
    deploy_notice+=" so ~/.claude may not be on origin/main. Details: ${deploy_log}."
    deploy_notice+=" Next: run claude-config-deploy status in a terminal."
  else
    stale_hours="${CLAUDE_CONFIG_DEPLOY_STALE_HOURS:-2}"
    [[ "${stale_hours}" =~ ^[0-9]+$ ]] || stale_hours=2
    ok_at=""
    { read -r ok_at <"${deploy_state}/deploy.ok"; } 2>/dev/null || true
    stale_text=""
    if [[ ! -e "${deploy_state}/deploy.ok" ]]; then
      stale_text="has never recorded a completed run"
    elif [[ ! "${ok_at}" =~ ^[0-9]+$ ]]; then
      stale_text="has no readable last-good time in ${deploy_state}/deploy.ok"
    else
      now="$(date +%s)"
      ok_age=$((now - 10#${ok_at}))
      # A stamp from the future (clock change) counts as fresh, not stale.
      if ((ok_age >= 0 && ok_age >= 10#${stale_hours} * 3600)); then
        if ((ok_age >= 86400)); then
          age_text="$((ok_age / 86400))d"
        elif ((ok_age >= 3600)); then
          age_text="$((ok_age / 3600))h"
        else
          age_text="$((ok_age / 60))m"
        fi
        ok_when="$(date -r "${ok_at}" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "${ok_at}")"
        stale_text="has not completed a run in ${age_text} (last good run ${ok_when})"
      fi
    fi
    if [[ -n "${stale_text}" ]]; then
      deploy_notice="claude-config DEPLOY STALE: the deploy agent ${stale_text}, so ~/.claude may be behind origin/main."
      deploy_notice+=" Check: claude-config-deploy status; launchctl print gui/\$(id -u)/com.smartwatermelon.claude-config-deploy."
      deploy_notice+=" Log: ${deploy_log}."
    fi
  fi
  if [[ -n "${deploy_notice}" ]]; then
    printf '%s\n' "${deploy_notice}"
    printf '⚠️  %s\n' "${deploy_notice}" >&2
  fi
fi
exit 0
