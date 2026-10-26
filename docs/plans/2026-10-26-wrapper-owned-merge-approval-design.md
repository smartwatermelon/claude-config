# Wrapper-owned merge approval — design

Status: DECIDED (2026-10-26), after an independent adversarial review. The
first draft (osascript dialog, Apple Messages, GitHub approval as phases) was
replaced by the smaller plan below.

## Problem

Agents treat the merge-lock as their job. CLAUDE.md Protocol 6 said every
merge needs a lock, with no exception. `pre-merge-review.sh` printed the full
`merge-lock.sh authorize …` command when a lock was missing. Memory files
repeat "all PR merges require a merge-lock". The result:

- Agents ask Andrew for locks on repos that `merge-lock-policy.conf` exempts
  (rule 37, `* exempt`, decided 2026-10-08, dev-env#176).
- Agents stall a merge waiting for a lock nobody needs.
- Agents read the printed `authorize` command and try to run it, or relay it
  to Andrew as a task.

Two bugs made it worse: the policy lookup failed on every machine checked, so
every merge fell into the lock path, exempt repos included.

- arich-mac: origin is an SSH host alias (`git@github-smartwatermelon:…`),
  which the origin check rejected.
- ASIAGO: the claude-config checkout was on a feature branch, and the policy
  was read only from a checked-out `main`.

## Rule

`merge-lock-policy.conf` decides how each repo merges, never the agent.

- **Default: the merge-lock workflow applies.** Every repo the policy does
  not specifically exempt needs Andrew's second-factor approval, in whatever
  form the workflow currently takes.
- **Exempt repos.** A repo or org is exempt when the second factor is
  unnecessary or already provided some other way. Two kinds:
  - `exempt`: personally owned repos where a second factor adds nothing. The
    agent merges after green CI and the pre-merge review.
  - `refuse`: orgs with their own approval process (for example review by a
    separate SRE team). Agents never merge; Andrew merges in the GitHub UI
    after that approval. No prompt, and an existing lock does not override it.

## Threat model

The agent holds tokens that can merge and can reach `api.github.com` without
going through `gh`. Local layers therefore guide a well-meaning agent that
takes shortcuts; they cannot stop a hostile one. Each local change is judged
by one test: would a well-meaning agent reach for this form? Hook regexes
against shell tricks (`HOME=<dir> gh pr merge`, `export …`) fail that test and
are not built. Real enforcement, where wanted, is server-side (see Later).

## Changes

### claude-config

1. `merge-lock.sh policy` gains the `refuse` outcome.
   `owner=beacon-biosignals refuse` moves above `author=andrewmrich lock` so
   it matches first.
2. `pre-merge-review.sh` prints one line and exits 1:
   - lock needed, none valid: `[gh] Not merged: <repo>#<N> needs Andrew's
     approval.` No command, no path.
   - refuse: `[gh] Not merged: <repo>#<N> is merged by Andrew in the GitHub
     UI after its own approval process; agents do not merge it.`
3. `policy_text` accepts an SSH host alias origin for
   `smartwatermelon/claude-config` and reads the policy from `refs/heads/main`
   whatever branch is checked out, still requiring local main to be on
   origin/main.
4. CLAUDE.md Protocol 6 is rewritten to the rule above, without naming any
   org: run `gh pr merge`; its result is final; never ask for or predict a
   lock.

### dotfiles (gh-wrapper.sh)

1. Function mode fails closed under Claude (`CLAUDECODE` set): a missing
   review script blocks the merge instead of "Proceeding without review".
2. Under Claude, the `_gh_wrapper_review_script` test override is ignored.

Andrew's interactive terminal keeps today's behavior.

### Andrew

Delete or correct project memories that say every merge needs a lock (for
example `dev-env/memory/reference_merge_lock_workflow.md`). The sandbox does
not let agents write there.

## Dropped from the first draft

- osascript dialog, Apple Messages, parallel channels, timeout budget,
  new ledger row types, pending-marker dedup. The agent's `Not merged` line
  is the prompt. A dialog may return later as UX only, if this proves
  insufficient.
- Hook regexes for environment-assignment prefixes.

## Later (separate plan)

Server-side enforcement for the owned, locked repos: route them to the
existing `smartwatermelon-agent` GitHub App so the agent is not the PR
author, require one approval with `enforce_admins`, and take admin-capable
PATs and the 1Password service-account token out of the agent environment.
Unverified: the PATs' and the App's exact permissions.

Known remaining local gaps (accepted under the threat model): `curl` to the
merge endpoint, `_GH_REVIEW_DONE=1` with `unset -f gh`, `bash -c`.
