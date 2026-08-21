# Field data: one real convergence run

Measurements from a 3-round run over 7 tech-debt issues in a shell/bats repo
(smartwatermelon/claude-config, 2026-08-20, 48 agents). These numbers are the
evidence behind the design rules in SKILL.md. They are one sample, not a law —
but every rule in the skill traces to something here.

## Follow-up amplification is real and greater than 1

| Measure | Value |
|---|---|
| Fix agents run | 24 |
| Follow-ups produced | 63 |
| Amplification | **2.6x** |
| Fixers returning zero follow-ups | 4 of 24 |

Each round produced substantially more candidate work than it closed. This is
the mechanism behind "the backlog never converges": absent a stopping rule, the
queue grows monotonically. A loop with no cap does not terminate on this repo.

## Severity distribution justifies the cosmetic floor

| Severity | Count | Share |
|---|---|---|
| blocking | 2 | 3% |
| real | 36 | 57% |
| cosmetic | 25 | **40%** |

40% of follow-ups were nit-level. Working them would have kept the loop alive
indefinitely on issues nobody asked for. Deferring cosmetic (file, never work)
is what makes termination reachable without discarding real findings.

## Verifiers are a major source of findings, not just a gate

29 of 63 follow-ups (46%) came from verifier `newConcerns`, not from fixers.

Harvesting follow-ups from the verification stage as well as the fix stage
nearly doubled discovered work. A design that only asks fixers "what else did
you find?" misses about half of it.

## The adversarial stage earned its cost

| Verdict | Count |
|---|---|
| holds: true | 21 |
| holds: false | 1 |

One rejection in 22 looks like a low yield until you read it. The rejected fix
was correct in its logic and passed the full bats suite — but broke a test in
`scripts/tests/*.sh`, a standalone bash suite that `bats tests/` does not run.

The fixer's claim "no new failures" was true of bats and false of the repo.

Worse: the broken assertion was a deliberate tripwire, pinned to expected-exit-0
precisely so it would trip when someone closed that gap. It tripped as designed
and the trip went unnoticed, because nobody ran the suite containing it.

Without the adversarial stage a genuine regression lands looking green.

## The verification command was incomplete, and the orchestrator caused it

The orchestrator's agent prompts specified `bats tests/` as the verification
command. The repo actually has two independent suites:

- `tests/*.bats` — 199+ tests
- `scripts/tests/*.sh` — 5 standalone suites, 177+ assertions

Every agent inherited the orchestrator's blind spot. The incomplete command was
not an agent error; it was authored once, at the top, and propagated to all 48.

**Establish the full verification command before dispatching anyone.** Enumerate
test suites by scanning for runners, not by recalling which one you used last.

## Same failure class appeared three separate times

All three were "a check that does not cover what it claims to":

1. bats suites resolving their subject through `${HOME}/.claude` symlinks —
   testing the deployed tree, not the working tree. A sabotaged constant
   (ceiling 900 -> 901) left all 22 tests passing.
2. Tests invoking a hook with stale arguments, so it exited at flag validation
   before reaching the logic under test. Green, and meaningless.
3. `bats tests/` presented as "the tests" while a second suite went unrun.

A backlog that keeps regenerating is worth checking for this directly. Fixes
land looking verified, vacuous green hides what is still wrong, and the next
review round rediscovers it as a fresh issue. That is a self-sustaining cycle
and no amount of rounds will drain it.

**Validate the check against a known-bad case before trusting a clean result.**
Break the thing on purpose. If the check still passes, the check is the bug.
