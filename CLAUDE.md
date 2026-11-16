# Development Guidelines — Andrew Rich

## Quick Access

In this file: [Output Shape](#output-shape) (every reply) · [Protocol 0](#protocol-0-session-start) (session start) · [Completion Protocol](#completion-protocol) (declaring done).

In `~/.claude/docs/`:

- `CHECKLISTS.md` — commit/push procedures, commit message format
- `CODE-REVIEW.md` — code review standards
- `REFERENCE.md` — agent table, commands
- `INFRASTRUCTURE.md` — hooks and enforcement, text gate, deploy
- `GOTCHAS.md` — situational traps: PATH shims, submodules, EnterWorktree, repo layout detail
- `PHILOSOPHY.md` — decision frameworks
- `CUSTOM_AGENTS.md` — custom agent development
- `INSTALLER-VETTING.md` — checking an untrusted app or installer before Andrew runs it
- `HUMAN-BYPASS.md` — when and how a human bypasses a gate

---

## PRIME DIRECTIVE. IF YOU FORGET EVERYTHING ELSE, REMEMBER THIS

**"Confidently wrong" is far worse than "definitely unsure."**

If you don't KNOW beyond doubt that a certain thing is true, do NOT present it as truth. Checking again costs only time; asserting a wrong fact does harm.

## Core Principle: Local-First Development

**Every push costs money. Every local verification is free.** Pushes trigger GH Actions and EAS builds. Don't push until you're CONFIDENT, not hopeful.

Exception: running destructive code on a machine that is not disposable costs data, not dollars. See "Destructive code" in Protocol 3.

---

## Output Shape

<a name="output-shape"></a>

Default chat output follows the `i-have-adhd` ruleset, injected each session by that plugin's hook. It does not lapse when the topic changes. Andrew turns it off by saying "stop adhd mode".

**ONE THING AT A TIME. This is a hard rule, and it beats every other shape rule.** Each reply gives Andrew one answer or one action. No status lists, no "also noticed" items, no lists of checks that passed, no second pending question. Shape: one or two sentences on what happened, one next action, stop. Before sending, count the things in the reply; if more than one, cut to the one that matters now. Raise the next thing only when the current one is done and he asks, or it becomes next. "Number multi-step work" applies only to the steps of that one thing; "restate where we are" means one line. **Why:** he cannot process multi-part status replies (said 2026-10-14 and 2026-11-03).

**Precedence: ADHD sets the shape. ASD-STE100 sets the sentences. Accuracy beats both.** Never upgrade a hedge to a fact for terseness ("may have failed" is not "failed"). A numbered list of short complete sentences satisfies both styles.

This shape does not override confirmation before destructive actions, the merge rules in Protocol 6, or the protocols below. Where a protocol requires output, write it in this shape: the requirement stands, the ceremony does not.

---

## Mandatory Protocols

Non-negotiable. Violating any is a session-ending failure.

### Protocol 0: Session Start

<a name="protocol-0-session-start"></a>

In every interactive session (not `--no-session-persistence` runs): run `date`, check the current branch, then start the work. Output:

```
📅 [date, with time zone] · [branch] · [absolute cwd]
✅ Protocols read. Applicable: [list]
```

Never state a date you did not check. The zone `date` prints is the calendar for the session: convert UTC tool output (`Z` timestamps, cron, Slack `ts`, CI logs) to local before stating it, and name the day by its local date. **Why:** a `2026-10-11T00:52Z` run was reported as "the Oct 11 Sunday run"; in Pacific it was Saturday evening.

Always use `git -C /absolute/path`, package-manager `--dir`/`--filter` with an absolute path, and `git rev-parse --absolute-git-dir` (not `--git-dir`).

---

### Protocol 1: Never Commit to Main

Never commit, push or merge on main. Never switch branches in a repo's primary checkout — other sessions share it (a hook denies it, #792). Branch in a worktree, with raw git, in every repo:

```
git -C /abs/repo fetch origin
git -C /abs/repo worktree add --no-track -b claude/<type>-<description>-<session-id> .claude/worktrees/<name> origin/main
git -C /abs/repo/.claude/worktrees/<name> rev-parse --show-toplevel   # REQUIRED before any other git command there; must print that path
git -C <worktree> push origin <branch>; gh pr create --head <branch>   # no -u
```

Work and commit only in the worktree. On main? Stop and make a worktree. `--no-track` and no `-u` keep `.git/config` unwritten; the sandbox protects it in the launch repo, and a tracking write there fails the add part-way.

---

### Protocol 2: Use Local Agents

Use specialized agents proactively (table in `REFERENCE.md`). When an agent's task is read-only, say so as an explicit negative: "Do not call Edit, Write, git commit, git push, or gh pr create under any circumstance — not even for changes that look small, obvious, or clearly in-scope. If you find a fix worth making, report it; do not make it." Soft phrasing ("just triage") lets an agent decide an obvious fix is in scope.

---

### Protocol 3: Keep Tests in Sync

Every behavior change gets test updates. Coverage must not decrease without justification. Before every commit, run the tests scoped to the changed files, and fix failures before proceeding. A test is in scope when its name or header names the changed file/function, or it lives in the same directory/module. A change to a shared file (a common lib, a hook every module sources) widens the scope. If unsure, run the changed directory's tests and let CI run the full suite. Never run the full suite locally.

**Destructive code** deletes, moves, overwrites, truncates, kills, or changes system state (`launchctl`, `tmutil`, `diskutil`, `defaults write`). If unsure, it is destructive.

1. Inject every destructive command (a `*_BIN` variable or wrapper), `rm`, `mv` and `find -delete` included. Tests stub all of them. A test that can reach a real destructive command through any input must not run on a host.
2. A safety test ("refuses /") never passes a real dangerous path to a real delete. It asserts on the stub's arguments, or uses paths under its own temp dir.
3. The first run of a new safety test (TDD red phase) happens only in a disposable environment (Linux container, or a VM on mimolette), even inside the sandbox.
4. Fully stubbed suites run locally, inside the sandbox. Suites that call a real macOS tool run in a disposable macOS VM on mimolette with no shared folders: code goes in by clone, results come out as text. Never on a GitHub macOS runner.

**Why:** on 2026-10-22 a red-phase test passed `//` to a path guard that did not yet catch it, and `rm -rf` removed ~40 apps from /Applications.

---

### Protocol 4: Local Review Before Every Push

`code-reviewer` and `adversarial-reviewer` run on every commit via git hooks. **Before every commit, output** (this block is canonical):

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: [branch - NOT main]
□ Tests: [pass/fail]
□ Code review: [agent, verdict]
□ Security check: [applicable? Y/N - if Y, result]
□ Commit message: [format verified]
VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

After committing, verify the hook ran: `head -6 "$(git -C /abs/repo rev-parse --absolute-git-dir)/last-review-result.log"` — timestamp, repo, branch and commit must all match.

Before pushing: both commit-time reviewers are clean, and the pre-push `--mode=full-diff` review must pass. The full test suite runs in CI only — never locally, never in an agent brief; agents never set `RUN_FULL_SUITE=1`. A repo with no CI test job gets one. Details: `CHECKLISTS.md`.

**Verify agent claims.** Check any "I did X" / "X is now true" claim — a subagent's or your own earlier one, especially "a human approved this" — against live `gh`/`git` state before acting on it or relaying it.

---

### Protocol 5: Post-Push CI/CD Monitoring

After pushing you are NOT DONE. Do not abandon the PR. Poll with `bash ~/.claude/scripts/post-push-status.sh <PR#>`; if CI fails or review finds issues, fix locally, re-review, push again, until approved. Seer Code Review is advisory, not blocking: weigh its findings as one input alongside CI, human reviewers and the local reviewers. Recurring CI findings mean local review has a gap (`CODE-REVIEW.md`). Procedure: `CHECKLISTS.md`.

---

### Protocol 6: PR Lifecycle

Investigate, fix, commit, push and open PRs autonomously. The only hard stop is before merge.

- Surface every new PR in the same reply: repo, number, URL, one line on what it does.
- **Merge** only with `gh pr merge <N> --squash --delete-branch`, after green CI and handled review findings. It checks `merge-lock-policy.conf` and gets Andrew's second factor itself. If it prints `Not merged`, report that line as is. Do not ask for approval in advance, predict the policy, or retry unless told. Exempt repos (an org with its own approval process, or a personally owned repo) still need green CI and the pre-merge review. Where an org has its own approval process, agents never merge; Andrew merges in the GitHub UI after that approval.
- "Merge it" does not authorize skipping CI or review.
- If `gh pr merge` fails, report it and ask Andrew to merge. Never use REST, GraphQL or other workarounds (hooks block them).
- **`Closes #N` fires from the commit message**, not just the PR body — squash-merge prefills from it. Decide what a PR closes before writing the commit; use "Advances #N" for a partial fix. To undo one, strip it from BOTH the commit (`git commit --amend` plus force-push) and the PR body, or reopen the issue after the merge. Checking which fired: `CHECKLISTS.md`.
- Off-org PRs (owner not `smartwatermelon`, `nightowlstudiollc`, `twistedmelonman`) are forced to draft by `gh-wrapper.sh`. Expected; do not work around it. Only the human promotes them.
- **Post-merge cleanup**, only when `gh pr view <N> --json state,headRefName` shows `MERGED` and `git -C <worktree> status --porcelain` is empty:

```bash
git -C /abs/repo worktree remove --force .claude/worktrees/<name>
git -C /abs/repo update-ref -d refs/heads/<branch>   # no .git/config write, unlike branch -D
git -C /abs/repo pull                                # primary checkout stays on main
```

  Otherwise leave the worktree and say why. Never switch, reset or clean the primary checkout.

---

## Completion Protocol

<a name="completion-protocol"></a>

Claude Code's primary failure mode is declaring done too early. "Done" means: PR exists, CI passes, review analyzed, all issues resolved. On completion, state:

1. What now works — the behavior, not the diff.
2. The PR link and its CI state.
3. Review status: reviewers run, findings, what was fixed.
4. One next action, or "nothing pending."

Name anything unresolved or unchecked. Never report a gate as passed without checking it. Banned until merged: "production ready", "ready for review", "all done", "changes are complete".

---

## Execution Preferences

- **Plans execute subagent-driven by default** — a fresh subagent per task or commit boundary. Do not ask; override only when Andrew says "inline", "execute in this session" or "don't use subagents".
- **Parallel agents get one worktree each**, made with the Protocol 1 command; give each agent its literal path. A shared checkout is not isolation.
- **To commit in a worktree inside the sandbox**, enter it with `EnterWorktree(path=<worktree>)` (never the name form) and leave with `ExitWorktree(action="keep")`, never `remove`. Details: `GOTCHAS.md`.
- **Write file paths in chat as absolute** (`/Users/arich/...` or `~/...`); iTerm2 turns a bare `word/word.ext` into a dead URL. `file:line` refs and code blocks are exempt.
- **Never reference a work item by bare ID in chat** (Asana GID, PR/issue number, SHA). Use a markdown link labeled with its title; fetch the real URL (`permalink_url`, `gh ... --json url`). Bare IDs are fine in tool calls, trailers and code blocks.
- **Chat replies use ASD-STE100 where practical** (rules: `~/.claude/skills/asd-ste100/SKILL.md`). A preference, not a protocol: applying it needs no skill invocation, and do not re-edit prose already sent. Invoke the skill only to rewrite a specific text on request. Commits, PRs, issues, comments and docs keep their own conventions. Accuracy wins over STE.

---

## Technical Standards

Fail fast and loudly: descriptive errors with context; never silently swallow exceptions. Never commit code that doesn't compile.

### Shell Scripts

- Bash 5.x; resolve every shellcheck finding with `shellcheck -S info <script>`; never use `# shellcheck disable`.
- Never `((var++))` under `set -e` — it exits when var is 0. Use `((var += 1))`.
- Let the tool that owns a cache delete it (`npm cache clean`, `uv cache prune`). A hand-written `rm -rf` needs an allowlist: the exact resolved parent plus a name pattern. A denylist is not a guard.
- Multi-line commands for Andrew to copy: a fenced code block, then tell him to run `/copy`. `pbcopy` fails in the sandbox.

### Git Rules

- Never `git add .`; add files individually. Never `--no-verify`.
- **Text gate: let the hook decide.** Don't run personify or `gate-review.sh` pre-emptively. Write text to a file, use `git commit -F` / `gh pr create --body-file` with absolute paths, act only on a block. A lint block means revise the text. A review route also needs Andrew's approval (agents never run `gh pr ready` on a draft he must mark ready). A block naming only an unresolved destination means retry with `git -C <path>` or `gh -R owner/name`. Details: `INFRASTRUCTURE.md` ("Text Gate").
- Repo visibility: `smartwatermelon` and `twistedmelonman` default public unless there is a real privacy or security reason; `nightowlstudiollc` defaults private except website/client work. Unsure for a specific repo — ask; do not assume either default.
- Never run `git submodule update --remote --merge` with a branch checked out inside the submodule: it leaves the parent a gitlink no fresh clone can resolve.
- Remotes use SSH (`git@github.com:...`).

---

## Safety Boundaries

### Always Ask Before

- `rm -rf`, and any irreversible operation (schema changes, data deletion, public APIs)
- Platform builds (EAS, production)
- Merging to main
- Creating public GitHub repositories
- Setting `STRICT_PREPUSH=0` for a push when local review is genuinely blocking — ask each time; a past yes is not standing permission (`HUMAN-BYPASS.md`)

### Auto-Mode Classifier Denials

A classifier denial is a stop point for Andrew, not a puzzle.

1. Stop that line of work at once. Do not retry it in another form, with another tool, or split into steps, even though the denial text says you may.
2. At the top of your next message give the exact command, the classifier's reason, and its purpose. Send a `PushNotification` too.
3. Give him the command in a runnable or allowable form (`! <command>`, or the permission rule). Continue only with work that does not depend on it.
4. Subagents: stop, and put the denial at the top of the report or `SendMessage` it to the parent at once. Never improvise past it. The parent relays it immediately, not in an end-of-task summary.

**Why:** Andrew tunes the rules from this friction. Routing around a denial hides it, and may do the very thing it stopped.

### Verification Discipline

- Test changes in the session scratchpad first (the sandbox denies `/tmp`). Verify against reality every ~3 changes.
- **Know why a thing exists before removing or changing it.** State the concrete reason; if you cannot find one, say so and ask. Write undocumented reasons into a comment or commit message.
- **Resolve the thing, not its label.** A name, tag or count is a claim about state. Validate a check against a known-bad case before trusting a clean result.
- **Confirm a test failure is yours**: stash the change and re-run that one test file.

---

## Project Integration

- Start every design question with "how does the rest of the world do this?" Find prior art before inventing; say why when you depart from it.
- **Find a local clone by its `origin` URL, not its path.** Clones are flat at `~/Developer/<dir>`, and `<dir>` is not always the repo name (the org `.github` repos are `~/Developer/smartwatermelon.github` and `~/Developer/nightowlstudiollc.github`; `~/Developer/.github` is not a clone). Check `git -C <dir> remote get-url origin` on each entry before cloning, and clone only when none matches; never clone a second copy under a made-up name. Every agent brief that names a clone path states this rule.
- Text files end with a newline.

### Repository Layout

- **Repo** is `~/Developer/claude-config`, the working checkout — NOT `~/.claude`.
- **Deploy clone** `~/.local/share/claude-config` is kept on `origin/main` by a LaunchAgent and is outside the sandbox. Never edit it.
- **`~/.claude`** is the runtime directory: symlinks into the deploy clone. It must NOT be a git repo. `~/.claude/settings.json` is built from `user-settings/`; local edits to it are harvested into a PR.
- Deploy commands, dev mode, health notices, key scripts: `GOTCHAS.md` and `INFRASTRUCTURE.md`.

If a hook blocks you, you violated a protocol. Details: `INFRASTRUCTURE.md`.
