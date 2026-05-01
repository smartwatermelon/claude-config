# Development Guidelines — Andrew Rich

## Quick Access

**Starting a session?** → [Protocol 0](#protocol-0-session-start)
**About to commit/push?** → Read `~/.claude/docs/CHECKLISTS.md`
**Declaring work complete?** → Read `~/.claude/docs/CHECKLISTS.md` (Completion Verification)
**Need agent reference?** → Read `~/.claude/docs/REFERENCE.md`
**Need commit format?** → Read `~/.claude/docs/CHECKLISTS.md` (Commit Message Format)

**Auxiliary Documentation:**

- Checklists & Procedures → `~/.claude/docs/CHECKLISTS.md`
- Code Review Standards → `~/.claude/docs/CODE-REVIEW.md`
- Infrastructure & Hooks → `~/.claude/docs/INFRASTRUCTURE.md`
- Philosophy & Decision Frameworks → `~/.claude/docs/PHILOSOPHY.md`
- Reference Material & Commands → `~/.claude/docs/REFERENCE.md`
- Custom Agent Development → `~/.claude/docs/CUSTOM_AGENTS.md`

---

## Core Principle: Local-First Development

**Every push costs money. Every local verification is free.**

Pushes trigger GH Actions ($0.008/min+) and EAS builds (limited). Local agents, tests, linting, and Simulator runs cost nothing. Don't push until you're CONFIDENT, not hopeful. One thorough local cycle beats three push-fix-push iterations.

---

## Mandatory Protocols

These are non-negotiable. Violating any is a session-ending failure.

### Protocol 0: Session Start

<a name="protocol-0-session-start"></a>

At the beginning of every **interactive session** (not focused analysis tasks invoked with `--no-session-persistence`):

1. Run `date` to confirm current date/time
2. Verify OS, shell, working directory
3. State session ID
4. Acknowledge: "I have read and will follow all MANDATORY PROTOCOLS"
5. List relevant protocols for this session

**Required output:**

```
📅 Environment Check:
- Current Date: [date]
- Session ID: [id]
- OS: [Darwin/Linux] | Shell: [bash version]
- Working Directory: [absolute path]

✅ Protocol Acknowledgment:
I have read ~/.claude/CLAUDE.md and will follow all MANDATORY PROTOCOLS.

Relevant protocols: [list applicable ones]

⚠️ CWD Discipline:
- NEVER use shell `cd` — Bash tool cwd is stateful
- ALWAYS use `git -C /absolute/path` for git commands
- ALWAYS use package manager `--dir` or `--filter` flags with absolute path
```

---

### Protocol 1: Never Commit to Main

```
✗ FORBIDDEN: git commit/push/merge on main
✓ REQUIRED: Create branch first: git checkout -b claude/<type>-<description>-<session-id>
✓ REQUIRED: Verify: git branch --show-current (must NOT be "main")
```

On main? Stop. Create a branch. Do not proceed.

---

### Protocol 2: Use Local Agents Aggressively

Use specialized agents proactively, not as a last resort. See `~/.claude/docs/REFERENCE.md` for the agent table.

---

### Protocol 3: Keep Tests in Sync

Every behavior change MUST have corresponding test updates.

```
□ Run FULL test suite (not isolated files) before every commit
□ If tests fail → fix BEFORE proceeding
□ If behavior changed → generate/update tests
□ Coverage must not decrease without justification
```

---

### Protocol 4: Local Review Before Every Push

Never push without clean local review. Both `code-reviewer` and `adversarial-reviewer` run automatically on every commit via git hooks.

**Before every commit, output:**

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: [branch - NOT main]
□ Tests: [pass/fail]
□ Code review: [agent, verdict]
□ Commit message: [format verified]
VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

After committing, verify the hook ran: `head -6 $(git rev-parse --git-dir)/last-review-result.log` — check timestamp, repo, branch, and commit fields all match.

**Push only after both reviewers are clean.** Full checklists: `~/.claude/docs/CHECKLISTS.md`

---

### Protocol 5: Post-Push CI/CD Monitoring

After pushing, you are NOT DONE. Monitor CI and iterate until approved. Do not abandon the PR. If CI fails or remote review finds issues, fix locally, re-review, push again.

Use `bash ~/.claude/scripts/post-push-status.sh <PR#>` to poll CI status. Seer Code Review is **advisory / non-blocking** — its inline findings flow through to the local pre-merge AI analysis but do not block merge. (Seer runs on Sentry infrastructure, which is flaky and rate-limited; treating it as blocking creates merge stalls. Examine its findings as one input alongside CI, human reviewers, and the local code-reviewer agents.)

Full procedure: `~/.claude/docs/CHECKLISTS.md` (Post-Push Procedure)

**Recurring CI findings = local-review failure**, not normal workflow. See `~/.claude/docs/CODE-REVIEW.md` (Recurring CI Findings Signal Local Review Gaps) for the feedback loop to close those gaps.

---

### Protocol 6: PR Lifecycle

**Creating a PR and merging a PR are ALWAYS two separate turns requiring two separate explicit authorizations.**

```
Step 1: gh pr create → report PR URL → STOP. Wait.
Step 2: CI runs → report CI status → STOP. Wait.
Step 3: Human says "merge it" for that specific PR → gh pr merge → STOP.
Step 4: Post-merge cleanup → return to clean main.
```

"Merge it" does not authorize skipping CI, review, or the merge-lock.

**Only allowed merge command:** `gh pr merge <number> --squash --delete-branch` (routes through pre-merge-review.sh)

PR merge requires prior `merge-lock auth <PR#> "ok"` from the user; wait for explicit approval before merging.

If `gh pr merge` fails: report the failure, ask the human to merge manually. Never use REST API, GraphQL, or workarounds. These are blocked by hooks. Enforcement details: `~/.claude/docs/INFRASTRUCTURE.md`

**Post-merge cleanup (Step 4):** After a successful merge, leave the workspace clean on main:

```bash
git switch main
git pull
git branch -D <merged-branch>        # -D required: squash merge means -d always fails
git status                            # examine any unstaged changes or untracked files
# Review what's dirty — if safe to discard:
git checkout -- .                     # discard unstaged changes
git clean -fd                         # remove untracked files/dirs
```

Before discarding, examine unstaged changes — they may be intentional uncommitted work. Ask before discarding if anything looks non-trivial. Note: `-D` (force delete) is required because squash merges rewrite history, so git never considers the branch "fully merged."

---

## Completion Protocol

**Claude Code optimizes for completion. This is its primary failure mode.**

"Done" means: PR exists, CI passes, PR review analyzed, all issues resolved.
"Done" does NOT mean: code written, tests pass locally, committed.

Before declaring work done, output the full Completion Verification template from `~/.claude/docs/CHECKLISTS.md`. Banned phrases until Stage 6 is complete: "production ready", "ready for review", "all done", "changes are complete".

---

## Execution Preferences

- **Plan execution defaults to subagent-driven.** When a plan is ready to execute, dispatch a fresh subagent per task (or per commit boundary) — do NOT ask "subagent-driven vs inline." The decision is pre-made. Override only when I explicitly say "inline," "execute in this session," or "don't use subagents."
- Rationale: the choice is always the same, and asking is a blocking question I often miss for minutes at a time. Defaulting eliminates wasted wall-clock time.

---

## Technical Standards

### Architecture

- **Composition over inheritance** — Use dependency injection
- **Interfaces over singletons** — Enable testing and flexibility
- **Explicit over implicit** — Clear data flow and dependencies
- **Fail fast, fail loudly** — Descriptive errors with context; never silently swallow exceptions

### Shell Scripts

- GNU Bash 5.x compatible; all shellcheck issues resolved (errors, warnings, info)
- Never use `# shellcheck disable` directives
- Never use `((var++))` with `set -e` — when var=0, this exits. Use `((var += 1))` instead.
- Run `shellcheck -S info <script>` after every script edit before committing
- **Multi-line shell commands for clipboard**: Write to `/tmp/cmd.sh` then `cat /tmp/cmd.sh | pbcopy` so the user gets clean clipboard content. The terminal renderer breaks copy-paste on code blocks (adds indentation/trailing spaces). See [claude-code#18170](https://github.com/anthropics/claude-code/issues/18170).
- **PATH-shim wrappers — reload shell before testing**: After symlinking a new script into `~/.local/bin` that shadows a system binary (ssh, gh, claude, etc.), bash's per-session hash table still points at the cached old location even though `command -v` reports the new one. Plain `cmd` invocations silently run the old binary; full-path invocations correctly hit the new shim. Always instruct the user to run `hash -r` or reload their profile before any functional verification. When debugging a "wrapper not running" complaint on any PATH-shim, first ask for `hash <cmd>` and `type -a <cmd>` output before diving into the wrapper's logic.

### Git Rules

- **Never `git add .`** — Add files individually
- **Never `--no-verify`** — Blocked by hooks; human must commit manually in emergencies
- **Always PRIVATE repos** — Never create public repos without explicit permission
- Prefer `git mv` / `git rm` over bare `mv` / `rm`
- Never commit code that doesn't compile
- Remote origin uses SSH (`git@github.com:...`) — HTTPS will fail with auth errors
- After `git commit --amend`, the pre-commit hook may create a stray branch; clean up with `git branch -D <stray-branch>` and `git reset --hard <amended-commit>`
- If `gh pr create` fails with "must first push", wait for the background push task to complete before retrying

---

## Safety Boundaries

### Always Ask Before

- Running `rm -rf`
- Initiating platform-specific builds (EAS, production)
- Merging to main
- Irreversible operations (schema changes, data deletion, public APIs)
- Creating public GitHub repositories

### Verification Discipline

- Test changes in `/tmp/` before applying to production code
- Batch size ~3 changes, then verify against reality
- More than 5 actions without verification = accumulating unjustified beliefs
- **Chesterton's Fence**: Before removing anything, articulate why it exists

---

## Project Integration

- Find similar features/components before building new ones
- Follow existing patterns, libraries, and test conventions
- Use the project's existing build system, test framework, formatter/linter
- Don't introduce new tools without strong justification
- Text files end with newline

### Repository Layout

- **Repo** lives at `~/Developer/claude-config` — NOT at `~/.claude`
- **`~/.claude`** is the deployed runtime directory, managed via symlinks created by `install.sh`; it must NOT be a git repo (`install.sh` removes `~/.claude/.git` if present)
- Submodules live under `plugins/marketplaces/`; initialize with `git submodule update --init --recursive`
- `docs/plans/` directory exists for design/planning docs and should be committed
- Key scripts: `install.sh` (symlink bootstrap), `scripts/update-tools.sh` (repair + submodule update), `scripts/post-push-status.sh <PR#>` (CI status polling)

---

## Infrastructure

Protocols are enforced automatically by git hooks and scripts. If a hook blocks you, you violated a protocol. Details: `~/.claude/docs/INFRASTRUCTURE.md`
