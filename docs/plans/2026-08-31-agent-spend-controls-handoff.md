# Agent spend controls — handoff

**Date:** 2026-08-31
**Status:** one commit landed (unpushed), two items designed but not built
**Origin:** session `62eef446` in `claude-config`, investigating session `91ef0da0`
in `huddle-transcribe` (2026-08-31) which cost **$42.04** in 2h16m.

This is a whole-environment workflow concern, not specific to either repo. It is
written to be resumable cold, on a different account, with no prior context.

---

## 1. The premise was wrong, and that matters

The task began as: *"you fell into a recursive loop of review cycles; write a
guard that cuts off fruitless loops after N cycles."*

There was no loop. I searched for one specifically:

| Signal | Observed |
|---|---|
| `run-review.sh` invocations | 3 |
| `pre-merge-review.sh` invocations | 0 |
| `merge-lock` invocations | 0 (human-invoked) |
| Reviewer agents spawned | 2, one parallel batch, never re-run |
| `git commit --amend` | 0 |
| Max spawn depth | 1 (no subagent spawned an agent) |
| **Max assistant turns between two consecutive human messages** | **33** |

That last row is the load-bearing one. Every cycle-counting design — "halt after
N review rounds", "halt after N turns without user input" — gets tuned somewhere
in the 50–100 range. **All of them would have watched this session burn $42 and
fired zero times.**

Do not rebuild a cycle counter. It cannot see this failure mode.

### What it actually was

From the session's `cost-state`:

```
cache_read ..... 51,204,875 tokens   (~93% of the bill)
cache_create ......  799,936
output ............  271,215
input .............   25,788
```

A **189:1 read-to-write ratio**. Cost tracks `turns × context size`, and context
grows monotonically within a turn chain (29K → 187K on the main thread; 0 → 205K
in the worst subagent). Two hours of forward progress at 200K context costs more
than ten review rounds at 20K. **Continuing was the expense, not repeating.**

Per-thread attribution (deduped by `requestId`):

| Thread | Type | Requests | cache_read | Share |
|---|---|---|---|---|
| `a78eb5a7` | general-purpose "fix findings" | 134 | **19.20M** | **38%** |
| main | — | 97 | 12.09M | 24% |
| `a360be39` | security reviewer | 54 | 3.66M | 7% |
| `aa023f3a` | general-purpose build #2 | 31 | 3.09M | 6% |
| `a962c964` | adversarial reviewer | 30 | 2.15M | 4% |
| `a6447e0d` | general-purpose build #1 (killed) | 22 | 1.63M | 3% |

One subagent was 46% of the session. It edited a single 1029-line file **30
times** and re-ran the test suite **29 times**, each against a 100K–205K context.
Progress was real (51 → 183 passing tests, 10 findings fixed including a verified
SQL injection and an AppleScript RCE) — it was just billed at a very high
per-turn rate.

Three distinct waste mechanisms, in order of cost:

1. **Built the wrong thing first.** Dispatched a folder-watching build at
   15:46:59; user hinted a better trigger existed at 15:50:28; killed the agent
   at 15:52:03 (`TaskStop`) and re-dispatched DB-triggered at 15:53:07. 1.63M
   tokens and a 28KB script discarded. The deciding fact — `huddle-transcribe`
   takes a session ID, not a file path — was already known; both the schema and
   the arg parser had been read. Only 12 API requests preceded the dispatch.
2. **Fine-grained editing at high context** (the 30-edit/29-run agent above).
   Induced by my own dispatch prompt demanding a regression test plus
   fail-before/pass-after proof for each of 10 findings.
3. **Scope change mid-flight.** Splitting `lint.yml` into its own PR forced a
   stash → ship → merge → restore round trip (largest segment, 33 requests). Side
   effect: the security reviewer read a mid-stash tree and produced two false
   findings that then had to be disproved.

---

## 2. What landed

**Commit `513c979`** on branch `claude/feat-loop-budget-guard-62eef446`,
**not pushed**, 1 commit ahead of `origin/main`.

```
scripts/hook-budget-guard.sh      258 ++++
settings.json                      22 ++
tests/test_hook_budget_guard.bats 307 ++++
```

A spend circuit-breaker that meters **tokens, not cycles**. A loop is only one
way to spend a lot; a cycle counter cannot see expensive linear work at all, so
spend strictly dominates as a trigger.

- **SubagentStop, 5M default.** Blocks the 19.2M outlier; the other four agents
  (1.6M/2.1M/3.1M/3.7M) pass untouched. Verified against the real subagent
  transcripts, not just fixtures.
- **Stop, 25M default**, with a 10M advisory warning first (`systemMessage`,
  never blocks). Would have fired around 16:10, roughly an hour before the
  expensive half of the session.
- Both env-overridable: `BUDGET_SUBAGENT_TOKENS`, `BUDGET_SESSION_TOKENS`,
  `BUDGET_SESSION_WARN_TOKENS`.

Three implementation facts worth not rediscovering:

- **Hooks receive no cost data.** Token usage and cost are exposed neither in the
  hook input JSON nor the environment. The guard therefore sums the transcript's
  per-message `usage` objects. Verified reproducible: requestId-deduped summing
  of `91ef0da0`'s transcript yields 12,092,622 for the main thread, matching the
  independent `cost-state` figure.
- **Dedup by `requestId` is load-bearing.** Retried/streamed requests are stored
  under a repeated id (65 twice, 17 three times in that session). Summing raw
  lines overcounts ~2x and would fire the guard at half its stated ceiling. The
  bats suite pins this from both sides so it cannot pass by returning zero.
- **`stop_hook_active` must be honored.** Verified in the v2.1.252 binary:
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8`, with the guidance string *"For
  Stop/SubagentStop hooks, check stop_hook_active in the input and return success
  while it's true."* The cap covers **both** events — public write-ups claiming
  SubagentStop is uncapped are wrong. Ignoring it gets the hook silently
  overridden exactly when it matters, and each wasted block costs a full-context
  turn, making the guard itself the leak.

Every failure path fails **open** (unreadable, missing, empty, truncated,
non-JSON → exit 0). A live transcript is not guaranteed flushed when the hook
fires, so a half-written final line is the normal case, not an edge case.

**Environment-wide by construction:** wired in user-level `settings.json` (which
is symlinked, so the wiring went live immediately) and keyed off the transcript
path in the hook payload. `huddle` appears exactly once in the script, in a
comment. No path or repo coupling. Verified end-to-end by firing the deployed
hook against a different repo's live session.

Test state at handoff: **343 bats passing, 0 failures** (26 new). shellcheck
clean at `-S info`, no disable directives. `scripts/tests` 8/9 —
`test-post-push-status.sh` fails identically without these changes (confirmed by
stashing), so it is pre-existing and unrelated.

---

## 3. Not built — the higher-leverage item

**Scoped subagent dispatch.** This is the one with the best measured return and
it is the natural next commit.

I measured what agents receive versus what they were told to read:

| Source | Tokens/agent | Avoidable |
|---|---|---|
| Harness-injected (global + project `CLAUDE.md`) | ~7.3K | mostly no |
| **My dispatch prompt's "read these in full"** | **~33K** | **yes** |

**82% of the ~40K per-agent entry cost was self-inflicted by prompt wording**, not
harness overhead. Five agents × ~40K ≈ 200K tokens spent before any agent did any
work — and subagents start cold, so none of it is cache-amortized.

Two structural facts that make this fixable:

- The global `CLAUDE.md` references `docs/*.md` in **prose**, not `@`-includes.
  Those 49KB are therefore **not** auto-injected; an agent reads them only if
  told to. The harness baseline is genuinely small.
- Agent frontmatter supports `tools:` / `allowed-tools:` / `disallowed-tools:`.
  There is **no** flag to suppress `CLAUDE.md` injection — `skipProjectInstructions`
  and `systemPromptAppend` return zero hits in the v2.1.252 binary. Don't hunt
  for one.

Worst single instance: the fix agent was told to read `tests/run-tests.sh` **in
full** — 1,685 lines, ~17K tokens. To *add* a test it needed the harness contract
(~19 function signatures plus one sample test), about 750 tokens. **A 96%
reduction on the largest single item.**

### Proposed shape

1. Write the discipline into `docs/` (probably `CUSTOM_AGENTS.md`, which already
   exists): dispatch prompts hand over **interfaces and contracts, not whole
   files**. Name the specific anti-pattern — "read X in full" for a file the
   agent will not modify.
2. Add purpose-built agent definitions under `agents/` with narrow `tools:` lists,
   replacing generic `general-purpose` spawns. `general-purpose` was 54% of the
   incident's cost per the account usage panel.
3. Add a pre-dispatch check for the *most* expensive failure — building the wrong
   thing. In the incident, 12 requests preceded a dispatch that was killed 5
   minutes later. Cheapest available guard: before dispatching a build agent,
   state the design decision and its evidence in one line; if the evidence isn't
   already in hand, ask the human first. One question would have saved the
   single largest line item.

A `PreToolUse` hook on `Agent` could enforce parts of this mechanically (e.g.
warn when a dispatch prompt exceeds N bytes, or when `git stash list` is
non-empty — the mid-stash reviewer produced two false findings). Designed, not
built; the doc + agent definitions are the higher-value first step.

---

## 4. Evaluated and rejected: Headroom

<https://github.com/headroomlabs-ai/headroom> — verified real: Apache-2.0,
68,217 stars, actively pushed. Its own description states the mechanism:
*"Compress tool outputs, logs, files, and RAG chunks **before they reach the
LLM**."* It is a **request-compression proxy, not a response cache**.

It does not address this problem, and the measurement is decisive:

- **96 of 96 consecutive requests grew in size; zero were identical.** Nothing
  for a response cache to replay.
- **Anthropic's prompt cache was already at a 98.5% hit rate** on the main thread
  (12.09M cache_read vs 187K cache_create). Across all five subagents: **98.0%**.
  The expensive 19.2M agent was the *best*-cached at **98.9%**.

The bill was not cache *misses*. It was 51.2M **already-90%-discounted** reads,
driven by monotonic context growth over ~370 turns. Headroom improves cache hit
rates and payload size; there was ~1.5% of hit-rate headroom left. It cannot
change how Anthropic bills reads that still reach the API.

Open Claude Code issues found while checking (relevant if this is revisited):

- **#1174** *"claude code's teammate agents receive broken or garbage context"* —
  open since 2026-06-19. Directly hits the subagent case.
- **#3017**, **#2857** — API errors wrapping Claude Code; #2857 is a tool-schema
  rejection (`tool_search_tool_regex_20251119`) after a Headroom upgrade.
- #951 (daemon `ANTHROPIC_BASE_URL` inheritance) and #1158 (1M-context downgrade
  behind a custom base URL) are both **CLOSED** — worth re-checking rather than
  assuming, since a 1M-context downgrade would matter here.

Headroom looks genuinely useful for bulky repetitive tool output (large JSON
result sets). That is a different problem than context growth.

---

## 5. Pre-existing problems found along the way

Both are real, neither was introduced here.

- **`claude-config#451` — false-green in the review tooling.** `review.skipThreshold`
  and `chunkSize` are independent knobs, so raising the former to clear a
  large-diff block yields a review that skips the files that matter and still
  reports PASS:

  ```
  Skipping huddle-watch (1029 lines > 800 chunk size)
  Skipping tests/run-tests.sh (1351 lines > 800 chunk size)
  Reviewed: 2/4 files
  Blocking issues: 0
  Chunked review passed
  ```

  Any guard that trusts a PASS from that path is trusting nothing.

- **Two structural loop drivers, untouched.** `run-review.sh` truncates
  `REVIEW_LOG` each run (only `DISAGREEMENT_LOG` accumulates), so each review
  cycle has no memory of prior cycles. And review findings auto-file as GitHub
  issues (`huddle-transcribe#6`, "Non-blocking review findings from PR #5"),
  which makes the backlog self-feeding by construction. The existing
  `skills/converging-issue-backlogs/` skill documents this exact trap: *"Read
  review findings before the tooling files them."*

Also worth knowing: `.git/claude-review-cache` is keyed on diff **content**, so
it dedups identical diffs but has no concept of "how many reviews has this branch
had." It is a duplicate-work guard, not a loop guard.

---

## 6. Why mechanical enforcement, not more guidance

The advisory version already existed and did not hold:

- `docs/REFERENCE.md:127` — "Stop after 3 failed attempts and reassess"
- `skills/converging-issue-backlogs/` — a full `spawn_ratio` convergence metric
  with five stop conditions and field data from a real 48-agent run

Neither fired, because both require *noticing* that you are in trouble. The
incident loop was emergent — I did not believe I was looping, so I would never
have invoked the skill. A hook needs no self-awareness. That is the whole
argument for the guard, and the reason the scoped-dispatch work in §3 should also
land as agent definitions and a hook rather than as prose advice alone.

Note the skill's own field data remains the best prior art here, and its core
metric (`spawn_ratio >= 1.0` twice ⇒ diverging) is still correct for the case it
targets: *explicit* multi-round loops. It is complementary to the budget guard,
not superseded by it.

---

## 7. Resuming

State: branch `claude/feat-loop-budget-guard-62eef446`, commit `513c979`,
**unpushed**, clean tree.

```bash
git -C ~/Developer/claude-config switch claude/feat-loop-budget-guard-62eef446
git -C ~/Developer/claude-config log --oneline -1     # expect 513c979
bats ~/Developer/claude-config/tests/                  # expect 343 ok, 0 not ok
```

Confirm the guard is live and reading the current session:

```bash
printf '{"hook_event_name":"Stop","transcript_path":"%s","stop_hook_active":false}' \
  "$HOME/.claude/projects/<project>/<session-id>.jsonl" \
  | BUDGET_SESSION_WARN_TOKENS=1000 ~/.claude/scripts/hook-budget-guard.sh
```

Expected: `{"systemMessage":"💸 Session spend: N.NM tokens (hard stop at 25.0M)."}`
and exit 0.

Suggested order:

1. **Push `513c979` and open a PR** (Protocol 6 allows autonomous PR creation;
   merge still needs CI green plus a merge-lock).
2. **Build §3** — the scoped-dispatch doc plus narrow agent definitions. Highest
   measured leverage (~33K tokens/agent, 96% on the worst file).
3. **Decide on §5's structural drivers** — whether to stop auto-filing review
   findings as issues, and whether `REVIEW_LOG` should accumulate.

Thresholds in §2 are calibrated to one incident. They are deliberately set below
what that session spent so they would have fired during it. Expect to retune
after a few real sessions; the bats suite pins the current defaults, so a retune
is a deliberate edit with a failing test, not a silent drift.

### Verification habits that paid off here

Both are already in the global `CLAUDE.md`; this session is evidence for them.

- **Resolve the thing; don't match its label.** The task named a review loop. The
  review scripts had run 3 times. Checking the actual invocation counts, rather
  than accepting the label, is what redirected the whole design from cycle-
  counting to spend-metering.
- **Validate the check against a known-bad case.** The dedup logic was falsified
  three ways (duplicates collapse, counter is not dead, distinct ids still sum)
  before being trusted, and the guard was run against the real 19.2M transcript
  rather than only fixtures. A clean result from an unfalsified check proves
  nothing.
- **Verify agent claims against live state.** Subagent reports in this session
  contained a wrong premise ("SubagentStop has no block cap" — it shares the
  default-8 cap) and two wrong issue states (#951/#1158 reported open, both
  closed). Both were caught by checking the binary and `gh` directly. Useful
  numbers, unreliable details.
