---
name: post-push-loop
description: "Use after pushing a PR branch to autonomously monitor CI, fetch remote review findings, generate fixes, and iterate until CI is clean or a hard decision is needed. Invoke as: /post-push-loop [pr-number]"
---

# Post-Push Loop

Autonomously iterate through the CI/review cycle after a push. Loop exits only when
external signals clear (CI green + no unresolved bot findings), or when a finding
requires a human decision.

## Invoke

```
/post-push-loop [pr-number]
```

If `pr-number` is omitted, auto-detect from `gh pr view --json number -q .number`.

---

## Protocol

### Before Starting

1. Confirm current branch: `git branch --show-current` — must NOT be `main`
2. Confirm PR number: `gh pr view --json number -q .number`
3. Confirm `POSTPUSH_LOOP` will be set for all git push calls in this session

### The Loop

Repeat until **Exit: Success** or **Exit: Escalate**:

---

#### Phase 1 — WAIT for CI to complete

Poll every 30 seconds:

```bash
bash ~/.claude/scripts/post-push-status.sh <PR_NUMBER>
```

Continue polling while `CI_STATE=PENDING` or `CI_STATE=EXPECTED`.

Timeout: if `CI_STATE` has not resolved after 15 minutes, escalate with reason
"CI did not complete within timeout — check for stuck jobs."

---

#### Phase 2 — EVALUATE termination

Parse script output:

- `CI_STATE=SUCCESS` AND no `FINDING` lines → **Exit: Success**
- `CI_STATE=FAILURE` OR `CI_STATE=ERROR` OR any `FINDING` lines → proceed to Phase 3

---

#### Phase 3 — CLASSIFY findings

For each `FINDING` line, classify as **CONFIDENT_FIX** or **ESCALATE**:

**CONFIDENT_FIX** (all of the following must be true):

- Finding has a specific `file=` and `line=` reference
- Fix is local to that file (no cross-file ripple required)
- Finding falls into a known pattern:
  - Lint or style error
  - Type error or missing type annotation
  - Missing null/undefined check
  - Unused import or variable
  - Test assertion mismatch with clear expected value

**ESCALATE** (any of the following):

- Finding is architectural ("this approach should be reconsidered")
- Finding touches a security-critical path:
  - Files matching: `**/auth/**`, `**/jwt/**`, `**/password/**`, `**/session/**`,
    `**/payment/**`, `**/billing/**`, `**/db/**`, `**/migrations/**`,
    `**/crypto/**`, `**/secrets/**`
- Finding references behavior not introduced by this branch
- Root cause is ambiguous (no specific file/line, or conflicting signals)
- Two findings appear to conflict with each other
- `CI_STATE=ERROR` (infrastructure failure, not code failure)

**If ANY finding is ESCALATE**: stop. Do NOT apply any fixes. Go to **Exit: Escalate**.

**If ALL findings are CONFIDENT_FIX**: proceed to Phase 4.

---

#### Phase 4 — FIX

Apply edits for each confident finding. Keep changes minimal — fix exactly what the
finding describes, nothing more.

After all edits:

```bash
git diff HEAD
```

Review the diff briefly. If the diff is larger than expected or touches files not
referenced in findings, treat as ESCALATE.

---

#### Phase 5 — COMMIT

```bash
git add <only the files you changed>
git commit -m "fix: address <summary of findings>

Post-push loop iteration N: <list of findings addressed>"
```

Note: the pre-commit hook will run automatically. If it blocks the commit, treat as
**Exit: Escalate** — surface both the hook finding and the remote finding.

Environment for push: set `POSTPUSH_LOOP=1` to bypass the Protocol 4 interactive prompt.

---

#### Phase 6 — PUSH

```bash
POSTPUSH_LOOP=1 git push
```

Return to Phase 1.

---

### Exit: Success

```
✅ POST-PUSH LOOP COMPLETE

PR #NNN | N iterations
CI state: SUCCESS
Unresolved bot findings: 0

Commits pushed:
  <list of commit hashes + messages>
```

### Exit: Escalate

```
⚠️  LOOP PAUSED — Human decision required

PR #NNN | Iteration N | CI: <state>

FINDING(S) requiring your input:
  [For each finding]
  Source: <bot>
  File:   <path>:<line>
  Comment: <text>
  Reason escalated: <reason>

CONTEXT:
  Fixes applied this session: <list or "none">
  Local review at last commit: passed / blocked
  Current CI state: <state>

OPTIONS:
  1. Provide direction here → I resume with your guidance
  2. Take over manually → type "take over" to exit loop
  3. Abandon → type "abandon" to exit, leave branch as-is
```

Await human response. Do not proceed autonomously.

---

## Hard Constraints

- Never exit with "clean" status based on your own assertion — only based on
  `CI_STATE=SUCCESS` AND no `FINDING` lines from the status script.
- Never apply fixes when any finding is classified ESCALATE.
- Never use `--no-verify` on any git command.
- Never push to `main`.
- Set `POSTPUSH_LOOP=1` on every `git push` call within this skill.
