---
name: converging-issue-backlogs
description: Use when an issue backlog keeps regenerating itself — fixes spawn follow-up issues that spawn more follow-ups across sessions, a "fix the backlog" task has no clear end, or you are about to build a multi-round agent loop over issues, tech debt, review findings, or audit results
---

# Converging Issue Backlogs

## Overview

A backlog that regenerates faster than it drains is a control problem, not a
work problem. The loop needs a stopping rule, an admission gate on new work, and
verification that can actually fail.

**Core principle: measure whether the loop is converging, and stop when it is not.**

A round that creates more work than it closes is diverging. More rounds make it
worse. The correct response is to halt and hand a human the design decisions that
no fixer agent is authorized to make.

## The Convergence Metric

Track this every round. It is the whole skill in one line:

```
spawn_ratio = (new work admitted this round) / (work actually landed this round)
```

- `< 1.0` — draining. Continue.
- `>= 1.0` for two consecutive rounds — **diverging. Halt and escalate.**

A round cap is a fuse, not a stopping rule: it bounds spend but says nothing
about whether the work is paying. Without the ratio a diverging loop reports
"hit the cap" and reads as normal completion.

Measured on a real 7-issue run: 24 fixes produced 63 follow-ups (2.6x); after
deferring cosmetics `spawn_ratio` was still **1.62** — diverging, and invisible
to a design that counted only rounds. See field-data.md.

## Required Structure

### Loop skeleton

```
seed queue from the backlog (human-filed issues are admitted by fiat)
each round:
  halt if a stopping condition fires (below)
  fix each queued item (isolated worktree per item)
  verify each fix independently  -> holds / does not hold
  integrate what passed          -> commit or PR; never leave work only in a worktree
  harvest proposed follow-ups from BOTH fixers and verifiers
  admit or reject each proposal  -> independent judge, not the fixer
  record round stats, recompute spawn_ratio
```

### Stopping conditions — all of them, each with a recorded reason

| Condition | Meaning |
|---|---|
| Queue empty | Converged. The success case. |
| `round > max_rounds` | Fuse blew. Report residue, do not imply completion. |
| `spawn_ratio >= 1.0` twice | Diverging. Escalate to a human. |
| Zero items landed in a round | Stuck. Grinding will not help. |
| Queue larger than ~2x the seed set | Judge is too permissive, or the codebase is worse than believed. |
| Depth ceiling (A->B->C->D) | The root fix was wrong at the design level. Do not descend further. |

A halt without a recorded reason is indistinguishable from a crash. Always
record which condition fired.

## Non-Negotiables

These are the parts that get skipped under pressure, and each one has been
observed failing in a real run.

### The verifier must change control flow

If a `holds: false` verdict does not re-queue, retry, or block integration, you
do not have verification — you have logging. Writing the verdict into a ledger
and proceeding is the most common way this fails, because the code still *looks*
like it verifies.

**Check:** grep your orchestrator for the verdict field. If it appears only in a
schema, a prompt, and a log line, nothing branches on it.

### The work must be integrated, not just described

An agent working in an isolated worktree, forbidden from committing, with the
orchestrator "handling git" — and the orchestrator never does. The loop returns a
detailed ledger describing fixes whose code no longer exists, and the next round
works against a tree missing the fix that spawned its follow-ups.

**Check:** name the exact step that moves code out of the worktree. If you cannot
point to it, it is not there. Recording metadata about a fix is not integrating
it — look for the command that transfers the diff, and confirm it runs *before*
cleanup. Have agents commit in their own worktree and report `commit`, `branch`,
and `worktreePath`; the orchestrator then `git fetch`es each branch into the main
repo. A worktree path you never captured is a diff you cannot retrieve.

### Establish the full verification command before dispatching anyone

The orchestrator's verification command propagates to every agent. Get it wrong
once and all N agents inherit the blind spot — and every "no new failures" claim
they make is scoped to a suite that does not cover the repo.

Enumerate test runners by scanning the repo, not by recalling which one you used
last. Repos routinely have more than one:

```bash
ls tests/ scripts/tests/ test/ 2>/dev/null
grep -rl 'bats\|pytest\|jest\|go test' --include='*.sh' --include='Makefile' . | head
```

Observed: a repo with `tests/*.bats` *and* five standalone `scripts/tests/*.sh`.
Agents ran only bats. A fix passed all 199 bats tests and broke a standalone
suite whose assertion was a deliberate tripwire. It tripped as designed, unseen.

### Validate the check against a known-bad case

A clean result from a check you have not falsified proves nothing. Break the
thing on purpose and confirm the check fails.

```bash
# sabotage the constant the tests assert on
sed -i.bak 's/^CEILING=900/CEILING=901/' subject.sh
run_tests   # MUST fail here. If it passes, the tests are not testing this file.
mv subject.sh.bak subject.sh
```

Observed three times in one run: tests resolving their subject through symlinks
to a deployed tree; tests calling a hook with stale args so it exited before the
asserted logic; and a second suite never run.

**This failure class is a prime suspect for the regenerating backlog itself.**
Fixes land looking verified, vacuous green hides what is wrong, the next round
rediscovers it as new. Fix the verification before running rounds.

## Admitting Follow-Ups

Agents are rewarded for finishing. Filing a follow-up is the cheapest way to
finish. Left ungated, this alone sustains the cycle.

**Require a concrete artifact** — a failing test, stack trace, or `file:line`,
not a description. "Error handling could be more robust" regenerates forever;
"`test_env.py::test_precedence` fails after this change" terminates.

**Judge proposals with a fresh agent**, not the fixer that wrote them.

| Class | Action |
|---|---|
| Displaced work — same unit as the parent, no new artifact | Reject. Send back into the parent fix. Not a new issue. |
| Pre-existing — real, but not caused by this fix | File outside the run. Do not let scope creep launder itself as follow-up. |
| Adjacent defect — real, reproducible, different unit | Admit at `depth + 1`. |
| Design flaw — implies the parent fix was wrong | Do not descend. Revert the parent and re-do it. |
| Duplicate — fingerprint matches an existing node | Reject and link. |

**Defer cosmetic findings: file them, never work them.** In the measured run,
40% of follow-ups were nit-level. Working them keeps the loop alive on issues
nobody asked for.

**Dedup against everything ever seen, not the current queue.** Deduping against
the working queue lets a rejected concern reappear each round forever.

**Harvest from verifiers too.** 46% of follow-ups came from the verification
stage, not the fix stage. Asking only fixers "what else did you find?" misses
about half.

## Red Flags — STOP

- "The verifier returns a verdict" — but nothing reads it
- "The orchestrator handles git" — name the line that does it
- "All tests pass" — which suites? did you enumerate them, or recall them?
- "No new failures" — scoped to what? falsified against a known-bad case?
- Round cap treated as the stopping rule, with no convergence measure
- A follow-up with no artifact, only a description
- A round reported as complete while its code sits uncommitted in a worktree

## Common Mistakes

| Mistake | Consequence |
|---|---|
| Round cap as the only stop | Diverging loop reports "capped", reads as normal |
| Verdict recorded, not acted on | Bad fixes land looking verified |
| No integration step | Ledger describes code that no longer exists |
| Verification command set from memory | Every agent inherits one blind spot |
| Trusting green without falsifying it | The check is the bug; backlog regenerates |
| Working cosmetic follow-ups | Loop never terminates |
| Dedup against the queue only | Rejected concerns return every round |

## Reference Implementation

`issue-convergence-loop.js` — a working Workflow script implementing everything
above: pipelined fix->verify chains, worktree isolation, verdict-driven re-queue
and quarantine, cumulative dedup, severity triage, and all five stop conditions.

Invoke with `Workflow({scriptPath: '<this dir>/issue-convergence-loop.js', args})`:

| arg | purpose |
|---|---|
| `repo` | `owner/name`, for `gh issue view` |
| `repoPath` | absolute path to the checkout |
| `issues` | seed issue numbers |
| `verifyCommand` | **every** suite, not a subset — enumerate by scanning |
| `knownFailures` | the pre-existing baseline, from a clean checkout of the base commit |
| `houseRules` | repo lint/style rules appended to every agent prompt |
| `maxRounds` | fuse (default 3) |
| `maxAttempts` | tries before quarantine (default 2) |

`verifyCommand` and `knownFailures` are the two worth care: both propagate
verbatim to every agent, so an error made once is inherited N times.

The script returns `{stopReason, roundStats, ledger, integrated, quarantined,
deferredCosmetic, unworked}`. Read `roundStats[].spawnRatio` first — it tells you
whether the work was paying.

`field-data.md` — measurements from a real 3-round, 48-agent run: amplification
rate, severity distribution, verifier yield, and the regression the adversarial
stage caught.
