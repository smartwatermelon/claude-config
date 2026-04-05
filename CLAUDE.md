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

Full procedure: `~/.claude/docs/CHECKLISTS.md` (Post-Push Procedure)

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

**Only allowed merge command:** `gh pr merge <number>` (routes through pre-merge-review.sh)

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
- **Multi-line shell commands for clipboard**: Write to `/tmp/cmd.sh` then `cat /tmp/cmd.sh | pbcopy` so the user gets clean clipboard content. The terminal renderer breaks copy-paste on code blocks (adds indentation/trailing spaces). See [claude-code#18170](https://github.com/anthropics/claude-code/issues/18170).

### Git Rules

- **Never `git add .`** — Add files individually
- **Never `--no-verify`** — Blocked by hooks; human must commit manually in emergencies
- **Always PRIVATE repos** — Never create public repos without explicit permission
- Prefer `git mv` / `git rm` over bare `mv` / `rm`
- Never commit code that doesn't compile

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

---

## Infrastructure

Protocols are enforced automatically by git hooks and scripts. If a hook blocks you, you violated a protocol. Details: `~/.claude/docs/INFRASTRUCTURE.md`

<!-- headroom:learn:start -->
## Headroom Learned Patterns
*Auto-generated by `headroom learn` on 2026-04-03 — do not edit manually*

### Pre-commit Hooks
*~800 tokens/session saved*
- This repo runs Semgrep static analysis and a review hook on every commit via `.pre-commit-config.yaml`
- Use `shellcheck -S info` to validate shell scripts before committing to avoid pre-commit failures
- Set `POSTPUSH_LOOP=1` env var when pushing to suppress certain hook behaviors: `POSTPUSH_LOOP=1 git push`

### PR Merge Protocol
*~600 tokens/session saved*
- Merging PRs requires `--squash --delete-branch` flags: `gh pr merge <N> --repo smartwatermelon/claude-config --squash --delete-branch`
- A merge-lock must be authorized by the user before merging: `merge-lock auth <PR#> "ok"`
- Seer Code Review check is treated as non-blocking until local dev-env workflow is implemented

### .gitignore
*~600 tokens/session saved*
- `docs/plans/` directory should be committed (not ignored); if git refuses to add it, check `.gitignore` for a `docs/plans` rule and remove it
- After editing `.gitignore` to remove an exclusion, run `git rm -r --cached .` and re-add, or verify with `git check-ignore -v <path>`

### Branch Policy
*~500 tokens/session saved*
- Never commit directly to `main`; always create a feature branch first: `git checkout -b claude/<feature-name>-<suffix>`
- The pre-commit hook (`hook-block-all.sh`) will block commits on `main` with exit code error

### Key File Locations
*~500 tokens/session saved*
- Repo lives at `~/Developer/claude-config` (NOT at `~/.claude`)
- `~/.claude` is the deployed runtime directory managed via symlinks from this repo
- `install.sh` manages symlinks from `~/Developer/claude-config` → `~/.claude`; run with `--dry-run` first
- Post-push status script: `~/.claude/scripts/post-push-status.sh <PR#>`

### Git Remote
*~400 tokens/session saved*
- The repo remote must use SSH, not HTTPS: `git@github.com:smartwatermelon/claude-config.git`
- If push fails with "Device not configured", fix with: `git remote set-url origin git@github.com:smartwatermelon/claude-config.git`

### gh pr create Timing
*~400 tokens/session saved*
- `gh pr create` fails with "must first push the current branch" if run immediately after `git push`; wait for push to complete or use a background task before calling `gh pr create`

### Submodules
*~300 tokens/session saved*
- Submodules under `plugins/marketplaces/` are not initialized by default; run `git submodule update --init --recursive` before working with them
- The superpowers-marketplace submodule lives at `plugins/marketplaces/superpowers-marketplace/`

### Shell Scripts
*~300 tokens/session saved*
- Project uses GNU Bash 5.x; Bash 5 features (process substitution, associative arrays, etc.) are explicitly acceptable
- Always run `shellcheck -S info <script>` before committing shell scripts

<!-- headroom:learn:end -->
