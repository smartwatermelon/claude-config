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
□ If subagent-driven-development was used: treat all subagent-reported reviews
  as UNVERIFIED. Before pushing, run a full-diff adversarial review manually:
    git diff main..HEAD | claude --agent adversarial-reviewer -p --tools ""
  Per-commit subagent reviews only cover incremental diffs — cross-cutting issues
  visible only across the full feature surface will be missed otherwise.
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
