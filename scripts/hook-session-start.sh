#!/usr/bin/env bash
# Hook: SessionStart - surfaces the pending-issues fallback queue
#
# Project-specific setup hooks can be configured in each project's
# .claude/hooks/ directory and invoked via the claude-wrapper's
# pre-launch hook mechanism (see ~/.local/bin/claude-wrapper).
#
# ~/.claude/pending-issues/ is where lib-review-issues.sh writes a finding it
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

PENDING_DIR="${PENDING_ISSUES_DIR:-${HOME}/.claude/pending-issues}"

# A missing directory is the normal case on a fresh machine, not an error.
[[ -d "${PENDING_DIR}" ]] || exit 0

# `find -print` piped to `wc -l` rather than a glob: an empty directory makes
# a glob expand to the literal pattern, which would count as one file.
# Each stage gets `|| true` so a find failure (unreadable dir) yields 0
# rather than masking a non-zero status mid-pipeline.
pending_count=$(
  { find "${PENDING_DIR}" -maxdepth 1 -name '*.md' -type f -print 2>/dev/null || true; } |
    { wc -l || true; } |
    { tr -d ' ' || true; }
)

[[ "${pending_count}" -gt 0 ]] || exit 0

# stderr, not stdout: stdout is the hook protocol's channel back to the
# harness, and this is a human-facing notice rather than hook output.
printf '⚠️  %s unfiled review finding(s) in %s\n' "${pending_count}" "${PENDING_DIR}" >&2
printf '   These are findings the reviewer could not file as GitHub issues.\n' >&2
printf '   Each records its target repo in its Repo header line; drain them by filing\n' >&2
printf '   each in that repo, then deleting the file.\n' >&2
