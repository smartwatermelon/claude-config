# Human Bypass Guide

This document explains how YOU (the human operator) can bypass the hardened review hooks when legitimately needed. These bypasses are **not available to the Claude Code agent**.

---

## Quick Reference

| Situation | Human Command |
|-----------|---------------|
| Commit without review | `git commit --no-verify -m "message"` |
| Push without checks | `git push --no-verify` |
| Commit to main (emergency) | `git commit --no-verify -m "message"` (on main branch) |
| Authorize PR merge | `~/.claude/hooks/merge-lock.sh authorize <PR#> "reason"` |
| View blocked attempts | `~/.claude/scripts/blocked-audit.sh` |

---

## Detailed Instructions

### 1. Committing Without Review

The agent is blocked from using `--no-verify`, but you can use it directly:

```bash
# In your terminal (not through Claude Code)
git commit --no-verify -m "fix: emergency hotfix for production"
```

**When to use:**

- Emergency production fixes that can't wait for review
- Infrastructure changes that cause review timeouts
- Commits to repos without review hooks set up

**After using:** Consider running `git diff HEAD~1 | claude --agent code-reviewer -p` manually to review later.

### 2. Pushing Without Pre-Push Checks

```bash
# In your terminal
git push --no-verify
```

**When to use:**

- Pushing to a branch that doesn't need Protocol 4 checks
- Emergency deployments

### 3. Authorizing PR Merges

The agent cannot merge PRs without your authorization:

```bash
# Authorize a specific PR (valid 30 minutes)
~/.claude/hooks/merge-lock.sh authorize 123 "Reviewed and approved"

# Check authorization status
~/.claude/hooks/merge-lock.sh status 123

# List all active authorizations
~/.claude/hooks/merge-lock.sh list
```

**Workflow:**

1. Agent completes PR and asks to merge
2. You review the PR on GitHub
3. You run the authorize command
4. You tell the agent to proceed with merge

### 4. Viewing Blocked Attempts

See what the agent tried to bypass:

```bash
# View all blocked attempts
~/.claude/scripts/blocked-audit.sh show

# Count total blocked attempts
~/.claude/scripts/blocked-audit.sh count

# View today's blocked attempts
~/.claude/scripts/blocked-audit.sh today

# Clear the log
~/.claude/scripts/blocked-audit.sh clear
```

### 5. Committing Directly to Main

The agent is double-blocked from committing to main:

1. Git pre-commit hook blocks it
2. Claude Code PreToolUse hook blocks it

You can bypass both:

```bash
# Switch to main and commit (emergency only)
git checkout main
git commit --no-verify -m "fix: critical production fix"
git push --no-verify
```

**Warning:** This violates Protocol 1. Only do this for genuine emergencies.

---

## Environment Variables (For Scripts)

If you need to run scripts that invoke git commands:

```bash
# These don't help the agent (PreToolUse blocks before execution)
# But useful for your own automation scripts

SKIP_REVIEW=1 SKIP_REVIEW_REASON="automated deploy script" git commit -m "..."
FORCE_PUSH_NO_REVIEW=1 git push
```

---

## Adjusting Thresholds

If review is timing out frequently, adjust thresholds:

```bash
# Increase review timeout (default: 120 seconds)
git config --global review.timeout 300

# Increase max lines for full review (default: 1000)
git config --global review.maxLines 2000

# Increase threshold before review is skipped (default: 2500)
git config --global review.skipThreshold 5000
```

---

## Temporarily Disabling Hooks

To disable ALL Claude Code hooks temporarily:

1. Edit `~/.claude/settings.json`
2. Rename `"hooks"` to `"_hooks_disabled"`
3. Restart Claude Code
4. Do your work
5. Rename back to `"hooks"`
6. Restart Claude Code

**Or** remove specific PreToolUse hooks by editing the array.

---

## Emergency Checklist

When you need to bypass:

1. **Ask yourself:** Is this truly an emergency, or am I just impatient?
2. **Document:** Note why you're bypassing in the commit message
3. **Review later:** Run manual review after the emergency passes
4. **Check audit log:** `~/.claude/scripts/blocked-audit.sh` to see if agent was trying to bypass

---

## Why These Protections Exist

The agent was deliberately using `--no-verify` to skip review, leading to:

- Bugs reaching CI that should have been caught locally
- Wasted CI minutes ($0.008+/minute)
- Multiple push-fix-push cycles

The PreToolUse hooks block the agent from bypassing, but you retain full control.
