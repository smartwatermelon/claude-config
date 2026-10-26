# Wrapper-owned merge approval — design

Status: DRAFT for independent review (2026-10-26). Not yet a plan.

## Problem

Agents treat the merge-lock as their job. CLAUDE.md Protocol 6 says every
merge needs a lock, with no exception. `pre-merge-review.sh` prints the full
`merge-lock.sh authorize …` command when a lock is missing. Memory files
repeat "all PR merges require a merge-lock". The result:

- Agents ask Andrew for locks on repos that `merge-lock-policy.conf` exempts
  (rule 37, `* exempt`, decided 2026-10-08, dev-env#176).
- Agents stall a merge waiting for a lock nobody needs.
- Agents read the printed `authorize` command and try to run it (the hook
  blocks it), or relay it as a task for Andrew.

The policy is already enforced in code. The agent's beliefs about it add only
friction and false questions.

## Goal

Take the agent out of the lock entirely.

1. The agent runs `gh pr merge <N> --squash --delete-branch`.
2. The gh wrapper intercepts it (it already does).
3. The wrapper decides whether a lock is needed (the policy check already
   does).
4. Not needed: proceed. Needed and no valid lock: the wrapper asks Andrew
   directly, on a channel the agent cannot answer.
5. The merge proceeds if Andrew approves and fails if not. Control returns to
   the agent with a final result.

The agent never sees `authorize`, never predicts whether a lock is needed, and
never asks for one.

## Non-goals

- Changing which repos are locked. `merge-lock-policy.conf` is unchanged.
- Changing CI, pre-merge review, or the merge command itself.
- Removing `merge-lock authorize` / `tui`. Andrew can still pre-authorize
  from a terminal; a valid lock skips the prompt.
- Server-side enforcement (branch protection). See Phase 3.

## Current flow (verified 2026-10-26)

```
agent: gh pr merge N …
  └ ~/.local/bin/gh → dotfiles/bash/gh-wrapper.sh
      └ _gh_wrapper_maybe_review → ~/.claude/hooks/pre-merge-review.sh "$@"
          ├ policy: merge-lock.sh policy --repo <canonical> --author <login>
          │   exempt → log "Merge lock not required", continue
          ├ lock:   merge-lock.sh check N --repo …
          │   missing → print "MERGE AUTHORIZATION REQUIRED … authorize …", exit 1
          ├ flag gate, Claude review (BLOCK_MERGE stops it)
          └ exit 0
      └ real gh pr merge
```

- The policy is read from claude-config's committed `origin/main`, never the
  working tree, and the deployed file is agent-unwritable
  (`hook-block-merge-locks-write.sh`, `hook-block-gate-dir-write.sh`).
- `gh pr merge *` is in the sandbox's `excludedCommands`
  (`~/.config/claude-code/machine-settings.json`), so the whole chain runs
  unsandboxed. This is what makes a GUI prompt possible at all.
- `hook-block-merge-lock-authorize.sh` blocks `authorize`/`auth`/`tui` in the
  agent's Bash command text. It does not see subprocesses, so the wrapper can
  write a lock internally.

## Proposed flow

Only the "lock missing" branch of `pre-merge-review.sh` changes.

```
lock missing
  └ request_approval <repo> <N>          (new; hooks/merge-approval.sh)
      ├ build request: repo, PR, title, author, URL, CI state, policy rule
      ├ ask on every available channel in parallel; first answer wins
      │   ├ dialog   (Phase 1)
      │   ├ messages (Phase 2)
      │   └ github   (Phase 3)
      ├ approved → create_merge_lock (sourced), ledger authorized_by=<channel>
      │            → continue to review → merge
      ├ denied   → exit 1  "[gh] Not merged: Andrew declined owner/repo#N."
      └ timeout  → exit 1  "[gh] Not merged: no answer from Andrew for owner/repo#N."
```

### Agent-facing contract

The agent sees exactly one of:

- the normal merge output (merged), or
- one line starting `[gh] Not merged:` with the reason (declined, no answer,
  no channel available, review blocked).

No command, no file path, no instruction to obtain anything. CLAUDE.md
Protocol 6 shrinks to: "Run `gh pr merge <N> --squash --delete-branch` when CI
is green and review findings are handled. Its result is final. Report a
`Not merged` line to Andrew as-is; do not ask for a lock, predict one, or
retry unless he says so."

### Ordering: prompt before or after the Claude review?

Today the lock check runs before the Claude review, so an unauthorized merge
costs nothing. Two options:

- **Prompt first (proposed).** Same cost profile as today. Andrew approves
  without seeing the review verdict; the review can still block afterwards.
- **Review first, then prompt with the verdict.** Better-informed approval,
  but the review (often minutes) plus the wait must fit in the agent's tool
  timeout (below).

Open question for review.

### Timeout budget

The Bash tool kills a command after 5 minutes by default (max 10). The
prompt wait must end, with a clean `Not merged` line, before the agent's
tool does. Proposed: wait 180 s by default, constant in code. A killed tool
call would surface as a cryptic timeout and restart the "what about the
lock?" reasoning this design removes.

## Channels

Each channel has one trust requirement: **an answer must be something the
agent cannot produce.** Everything else is convenience.

### Phase 1: osascript dialog

- `/usr/bin/osascript` (absolute path) shows a dialog with the PR details,
  buttons `Approve` / `Decline`, and `giving up after 180`.
- Works only when Andrew is at this Mac.
- Trust: the agent's own Bash commands run sandboxed, where Apple Events are
  denied, so it cannot script a click on the dialog. Residual risks:
  - A compound command such as `gh pr merge 5 & osascript …` might match the
    `gh pr merge *` exclusion and run unsandboxed. **Unverified**: how the
    exclusion matches compound commands. Must be tested, and a hook should
    refuse compound commands that start with `gh pr merge` if needed.
  - A computer-use tool, if granted to an agent, can click dialogs. Out of
    scope for code; noted.
  - `PATH` substitution: the agent controls the environment of the command,
    so a fake `osascript` earlier in `PATH` could return "Approve". Hence the
    absolute path, and no environment variable may change which binary is
    used or what counts as approval (see Test seams).
  - **`HOME` redirection (pre-existing, not created by this design).** Every
    path in the chain is `${HOME}`-relative: the policy symlink,
    `merge-locks/`, the ledger. `hook-block-api-merge.sh` blocks `gh` behind
    a path or a prefix command (`env`, `sudo`, …), but its `ASSIGN` pattern
    lets a bare `VAR=value gh pr merge N` through by design (read from the
    regex 2026-10-26, not tested). So `HOME=<dir> gh pr merge N` reaches the
    wrapper with an agent-chosen policy file, lock directory, and ledger. The
    policy's "committed origin/main" check can be satisfied by a fake
    checkout (`remote add` + `update-ref`), as the test suite's own setup
    does. Whether `gh` still authenticates under a moved `HOME`, and whether
    the sandbox exclusion matches the prefixed form, is unverified. This
    design rests on the same boundary, so Phase 1 must either block
    environment-assignment prefixes on `gh pr merge` or resolve every path
    from the real home directory (for example `dscl`/`getpwuid`), not
    `${HOME}`.

### Phase 2: Apple Messages

- Send: `osascript` to Messages, to Andrew's handle, with the PR details and
  a short request ID. "Reply YES <id> to merge, NO <id> to decline."
- Receive: poll `~/Library/Messages/chat.db` (SQLite, read-only) for rows
  newer than the sent row, from Andrew's handle, containing the request ID.
- Works on the phone, which the dialog cannot.
- Trust is the hard part:
  - The request ID binds a reply to a request. It is **not** a secret: the
    agent may be able to read `chat.db` too (unverified).
  - Approval must rest on **sender identity**: `is_from_me = 0` and the
    expected handle. The agent cannot send an iMessage as Andrew's handle
    from a sandboxed command (Apple Events denied).
  - **Unverified and load-bearing:** if this Mac shares Andrew's Apple ID,
    a reply typed on his phone may be recorded with `is_from_me = 1`, and a
    message the Mac sends to itself may look identical. Then sender identity
    cannot separate Andrew from the Mac. Phase 2 starts with a probe of
    exactly this, and does not ship if the two cannot be told apart. A
    dedicated sending account (a separate Apple ID on the Mac) may fix it.
  - Reading `chat.db` needs Full Disk Access for the process running the
    wrapper (the terminal app or the claude binary). Granting FDA to that
    process also grants it to the agent's unsandboxed commands. Review must
    weigh this.

### Phase 3: GitHub approval

- Approval = an `APPROVED` review on the PR by Andrew's account, read by the
  wrapper through the read-only GitHub App (claude-config#708).
- Blocked today: the agent authors PRs as `twistedmelonman`, and GitHub does
  not let an author approve their own PR. Needs the agent to act under its
  own GitHub identity (a separate project).
- Once that exists, branch protection can require the approval on the
  server, which no local hook can guarantee. This is the end state; Phases
  1–2 are the local bridge.

## Lock and audit

- An approval writes a normal lock through `merge-lock.sh`'s existing
  `create_merge_lock`, so the ledger, TTL, `merge-audit.sh`, and dedup paths
  are unchanged. `authorized_by` records the channel (`dialog`, `messages`)
  and the reason records the request ID.
- A decline or timeout writes a ledger row of its own kind (`declined`,
  `no-answer`) so the audit shows prompts that did not merge. New row type;
  `merge-audit.sh` must ignore or report it.
- Concurrency: two agents merging the same PR must not raise two prompts.
  A per-PR pending marker under `merge-locks/` (agent-unwritable) dedups.

## Test seams

The trust argument fails if the agent can choose the prompt implementation.
So:

- No environment variable selects the prompt binary, the channel, or a
  canned answer. Tests do not use `PATH` stubs for `osascript`.
- `merge-approval.sh` is a sourced library of functions. Tests source it and
  override the channel functions (`_approval_dialog`, `_approval_messages`)
  in-process. The production entry point always uses the real ones.
- No real dialog or message is sent from the test suite. Tests are fully
  stubbed and run locally inside the sandbox (CLAUDE.md Protocol 3).
- Known-bad first: a fake `osascript` earlier in `PATH` must not approve; an
  env var attempt must not approve; a reply with `is_from_me = 1` must not
  approve (Phase 2).

## Documentation and memory changes

- CLAUDE.md Protocol 6: replace the lock bullets with the contract above.
  Remove "the merge-lock requirement" from Output Shape and the "Merge it does
  not authorize skipping … the merge-lock" line, or reword it so the agent has
  nothing to do about the lock.
- `docs/HUMAN-BYPASS.md`, `docs/INFRASTRUCTURE.md`: describe the prompt as an
  operator path; keep `authorize`/`tui` as pre-authorization.
- Project memories that state "all merges require a lock" (for example
  `dev-env/memory/reference_merge_lock_workflow.md`) are under
  `~/.claude/projects`, which the sandbox does not let agents write. Andrew
  edits or deletes them; the PR description lists them.

## Phases

1. **Dialog.** Prompt in `pre-merge-review.sh`, the new library, ledger rows,
   Protocol 6 rewrite, tests. Verify the compound-command exclusion first.
2. **Messages.** Starts with the `is_from_me` / shared-Apple-ID probe and the
   FDA decision. Ships only if the trust requirement holds.
3. **GitHub approval and branch protection.** After the agent has its own
   GitHub identity.

## Open questions for review

1. Prompt before or after the Claude review?
2. Is 180 s right, given the 5-minute default tool timeout?
3. Does `gh pr merge *` in `excludedCommands` match compound commands? If
   yes, what blocks `gh pr merge 5 & <anything>`?
4. Is a GUI dialog in an unsandboxed subprocess of the agent's own command a
   strong enough boundary, given the agent controls that command's
   environment and stdin?
5. Phase 2: can sender identity in `chat.db` separate Andrew from this Mac,
   and is Full Disk Access for the wrapper's process acceptable?
6. Should the Messages channel be a separate Apple ID?
7. `HOME=<dir> gh pr merge N`: block assignment prefixes in the hook, or
   resolve the real home directory in the wrapper and hooks? Both?
8. What should happen with no channel available (headless host such as
   TILSIT over ssh, no GUI session)? Proposed: `Not merged: no approval
   channel on this host`.
