# Checklists & Procedures — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - Before committing (Pre-Commit Checklist)
> - Before pushing (Pre-Push Checklist)
> - Before declaring work complete (Completion Verification)
> - When writing commit messages (Commit Message Format)
> - After pushing a PR (Post-Push Procedure)

---

## Pre-Commit Checklist

```
□ On feature branch (NOT main): git branch --show-current
□ Tests pass (project-specific test command) - RUN LOCALLY FIRST
□ Linter clean (if applicable) - RUN LOCALLY FIRST
□ Type checking passes (if applicable) - RUN LOCALLY FIRST
□ AI review clean: git hook auto-runs code-reviewer agent (FREE, local)
□ Adversarial review clean: git hook auto-runs adversarial-reviewer on EVERY commit (FREE, local)
□ Verify hook review ran AND matches this repo: after EVERY commit, read the log header:
    head -6 $(git rev-parse --git-dir)/last-review-result.log
  Check ALL of the following — a timestamp alone is not enough:
  1. Timestamp within ~60 seconds (hook ran for this commit)
  2. repo: field matches this repo's root path
  3. branch: field matches your current branch
  4. commit: field matches HEAD (git rev-parse --short HEAD)
  If ANY field is missing or wrong: treat as unreviewed. Do not push.
  (The global ~/.claude/last-review-result.log is now a pointer file with a log: field
   pointing to the per-repo authoritative log.)
□ Never claim "AI review: N clean iterations" without seeing actual review output (Bash tool or log file)
□ No console.log/print statements in production code
□ No hardcoded secrets
□ No commented-out code
□ Commit message follows conventional format
```

---

## Pre-Push Checklist

```
□ All pre-commit checks pass
□ Adversarial review clean (runs on every commit via hook)
□ Dry-run the pre-push codebase reviewer and FIX what it finds, before pushing
  (see "Pre-Push Review Dry-Run" below). The pre-push hook files its
  non-blocking findings as GitHub issues; reading them first means fixing
  them instead of inheriting a backlog.
□ If subagent-driven-development was used: treat all subagent-reported reviews
  as UNVERIFIED. Before pushing, run a full-diff adversarial review manually:
    git diff main..HEAD | claude --agent adversarial-reviewer -p --tools ""
  Per-commit subagent reviews only cover incremental diffs — cross-cutting issues
  visible only across the full feature surface will be missed otherwise.
□ Branch is current with base (soft recommendation, not a hard gate):
    git fetch origin && git rebase origin/main   # or origin/<default-branch>
  Prevents GitHub's "branch out of date" banner. Skip when the branch is
  already current, shared/collaborative, or under active review where
  rebasing would invalidate in-progress review comments — use judgment.
□ Tests pass IN SIMULATOR (for mobile) or local environment
□ Linting and type checking clean locally
□ You are CONFIDENT this will pass CI, not just hopeful
□ You have done EVERYTHING verifiable locally
□ Branch pushed to origin
□ PR created with comprehensive description
□ Ready to monitor CI and respond to reviewer
□ Will not context-switch until Protocol 5 complete
```

---

## Pre-Push Review Dry-Run

The pre-push hook runs a whole-codebase review and **files every non-blocking
finding as a GitHub issue**. Learning about findings after the push means
inheriting them as a backlog; running the same reviewer first means fixing
them.

Run the reviewer the hook would run, with `gh` stubbed out so it cannot file:

```bash
mkdir -p /tmp/dryrev/bin
printf '#!/bin/sh\nexit 1\n' > /tmp/dryrev/bin/gh
chmod +x /tmp/dryrev/bin/gh

git diff origin/main...HEAD > /tmp/dryrev/diff.txt
PATH="/tmp/dryrev/bin:$PATH" ~/.claude/hooks/run-review.sh --mode=codebase \
  < /tmp/dryrev/diff.txt > /tmp/dryrev/out.txt 2>&1

grep -c 'NON_BLOCKING_ISSUE:' /tmp/dryrev/out.txt   # 0 means nothing will be filed
sed -n '/NON_BLOCKING_ISSUE:/,/END_ISSUE/p' /tmp/dryrev/out.txt
```

Fix what it reports, commit, re-run until the count is 0, then push.

**Why the stub:** filing is gated on the output containing
`NON_BLOCKING_ISSUE:`, and `gh` failing makes the filing step fall back to a
local file under `~/.claude/pending-issues/` instead of creating an issue. If
that write also fails the findings are dropped with a warning — but you are
reading them from `out.txt` anyway, which is the point of the dry-run.

**Bonus:** the review cache is keyed on the diff hash, so a clean dry-run makes
the real push a cache hit — it reports "Codebase review cached: identical diff
previously passed" and does not re-review.

### Treat findings as claims, not facts

A finding can be right about *what* to change and wrong about *why*. One in
this repo asserted that `[\n]` in an ERE bracket matches a literal `n` and not
a newline, with a `VERIFIED:` block stating so; a one-line check showed the
opposite. The conclusion (dead weight, remove it) was still correct.

Check the mechanism before acting on it, especially when the finding explains
how a tool or runtime behaves. That is what `lib-review-issues.sh` Group 3
exists to flag, and it applies to findings about your own diff too.

### Do not loosen a matcher without pinning the true positives first

When a finding asks you to stop something from matching, build the corpus of
cases that MUST still match before you touch the pattern, and re-run it after.
A fix to the api-merge hook here omitted `$(` from a command-position anchor —
command substitution executes, so that silently un-blocked a real bypass. The
existing suite caught it. Falsify in both directions: the loosened case must
now pass, and every previously-blocking case must still block.

---

## Verification Checkpoint (output before EVERY commit)

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: [current branch - must NOT be main]
□ Tests: [pass/fail - if fail, must fix before commit]
□ Code review: [agent used, verdict]
□ Security check: [applicable? Y/N - if Y, result]
□ Commit message: [follows format? Y/N]

VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

---

## Completion Verification (output before declaring work "done")

"Done" means: PR exists, CI passes, PR review analyzed, all issues resolved.
"Done" does NOT mean: code written, tests pass locally, committed.

Banned phrases until Stage 6 is complete: "production ready", "ready for review", "all done", "changes are complete".

```
📋 COMPLETION VERIFICATION:

STAGE 1 - LOCAL REVIEW:
  [✓] Code reviewed by: [agent]
  [✓] Verdict: [result]
  [✓] Issues fixed: [count]

STAGE 2 - COMMIT:
  [✓] Commit hash: [hash]
  [✓] Branch: [branch-name]
  [✓] Message format: [verified]

STAGE 3 - PUSH:
  [✓] Pushed to: [remote/branch]
  [✓] Push successful: [Y/N]

STAGE 4 - PR CREATED:
  [✓] PR number: [#NNN]
  [✓] URL: [link]

STAGE 5 - CI/CD STATUS:
  [✓] CI status: [waiting/passed/failed]
  [✓] If failed: [action taken]

STAGE 6 - PR REVIEW ANALYSIS:
  [✓] Automated reviews: [analyzed]
  [✓] Issues found: [count or "none"]
  [✓] Action needed: [describe or "none"]

ALL STAGES COMPLETE: [YES/NO]
```

---

## Post-Push Procedure (Protocol 5)

After pushing, you are consuming paid CI/CD resources. Do not abandon the PR.

```
1. Push PR: git push -u origin <branch>
2. Create/update PR: gh pr create --fill (or gh pr edit)
3. WAIT & MONITOR CI:
   gh run list --limit 5
   gh run watch              # interactive monitoring
   gh pr checks              # check status
4. If CI fails:
   - Review failure: gh run view <run-id> --log-failed
   - Fix locally
   - Push fix
   - GOTO step 3
5. WAIT for PR review comments (automated or human):
   gh pr view --comments
6. Analyze reviewer suggestions
7. Implement valid suggestions
8. CRITICAL: Follow Protocol 4 - Run local code-reviewer on fixes before pushing
9. Address local review findings (may take multiple iterations)
10. Push fixes, GOTO step 3
11. LOOP until:
   ✓ CI passes (all checks green)
   ✓ PR Reviewer has no blocking comments
   ✓ All automated feedback addressed

ONLY THEN is the PR ready for merge approval.
```

---

## Commit Message Format

```
<type>(<scope>): <subject>

<body - what and why>

AI review: <N> clean iterations  ← ONLY write this if you SAW the output (Bash tool or ~/.claude/last-review-result.log)
[Adversarial review: <N> iterations - <brief fixes>]
[Architectural review: approved/concerns]
Issues fixed: <brief list>

<footer - references>
```

**Types**: feat, fix, docs, style, refactor, test, chore

**Example**:

```
feat(auth): add JWT token refresh mechanism

Implements automatic token refresh 5 minutes before expiration.
Uses refresh token stored in secure HTTP-only cookie.

AI review: code-reviewer (2 iterations)
Adversarial review: code-critic:adversarial-reviewer (1 iteration) - fixed race condition in token refresh
Security-critical files: src/auth/jwt.ts, src/auth/refresh.ts

Closes #42
```

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
