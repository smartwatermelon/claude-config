# Development Guidelines — Andrew Rich

## Quick Access

**Starting a session?** → [Protocol 0: Session Start](#protocol-0-session-start)
**About to commit?** → [Protocol 4: Local Review](#protocol-4-local-review-before-every-push)
**Declaring work complete?** → [Completion Protocol](#completion-protocol)
**Need agent reference?** → [Agent Reference](#agent-reference)
**Need commit format?** → [Commit Message Format](#commit-message-format)
**Need checklists?** → [Verification Checklists](#verification-checklists)

**Auxiliary Documentation:**

- Philosophy & Decision Frameworks → `~/.claude/docs/PHILOSOPHY.md`
- Reference Material & Commands → `~/.claude/docs/REFERENCE.md`

---

## 🔴 MANDATORY PROTOCOLS

**These protocols are NON-NEGOTIABLE. Violating any of them is a session-ending failure.**

### 💰 Cost Consciousness: Local-First Development

**EVERY PUSH COSTS MONEY. LOCAL REVIEWS ARE FREE.**

- GH Actions: $0.008/minute (macOS runners cost more)
- EAS builds: $29-99/month depending on plan, limited builds
- Local code-reviewer: FREE
- Local adversarial-reviewer: FREE
- iOS Simulator: FREE
- Local test suite: FREE

**The Rule: Don't push until you're CONFIDENT, not just hopeful.**

Push-Fix-Push cycles are expensive. One thorough local review cycle is cheaper than three push iterations.

**Before pushing, ask: "Have I done everything I can verify locally?"**

- Run ALL applicable agent reviews locally (code-reviewer, adversarial-reviewer)
- Run full test suite locally
- Test in Simulator (mobile) or local environment
- Verify linting and type checking
- Only push when you would bet money that CI will pass

**CRITICAL**: Remote review finding issues that local review could have caught = you wasted money and skipped proper verification.

---

### ⚠️ CRITICAL: Code Review Cannot Be Bypassed

**`--no-verify` IS BLOCKED.** Claude Code hooks will reject any command containing this flag.

The review hooks exist because:

1. **Unreviewed code wastes CI money** - bugs caught in CI cost $0.008+/minute
2. **Local review is FREE** - catch bugs before pushing, not after
3. **Protocol 4 is mandatory** - not a suggestion

If review times out:

- Retry the commit (transient failures happen)
- Increase timeout: `git config review.timeout 300`
- Split into smaller commits

**Emergencies:** If you truly cannot proceed, ask the human to commit manually.
Do not rationalize skipping review. Do not apologize and then bypass anyway.

---

### Protocol 0: Session Start

<a name="protocol-0-session-start"></a>

**At the beginning of EVERY interactive session, I MUST:**

1. ✓ Run `date` to confirm current date/time
2. ✓ Verify OS and shell (Darwin/Linux, bash version)
3. ✓ Check available tools before using them
4. ✓ State session ID or timestamp for reference
5. ✓ Explicitly acknowledge: "I have read and will follow all MANDATORY PROTOCOLS"
6. ✓ List protocols relevant to today's expected work
7. ✓ Confirm understanding of global infrastructure availability

**Session Types**:

Protocol 0 applies to **interactive sessions** only. It does NOT apply to **focused analysis tasks**.

- **Interactive Session**: Claude Code CLI used for development work, code review, implementation tasks
  - Protocol 0 **APPLIES**: MUST output environment check as shown below
  - Examples: Normal Claude Code usage, implementing features, reviewing code interactively

- **Focused Analysis Task**: Invoked by scripts with `--no-session-persistence` for specific output parsing
  - Protocol 0 **DOES NOT APPLY**: Output must match expected format exactly, no preamble
  - Examples: `pre-merge-review.sh`, `run-review.sh`, other automation scripts
  - Detection: If invoked with `--no-session-persistence` flag, this is a focused analysis task

**Required Output Format:**

```
📅 Environment Check:
- Current Date: [output of date command]
- Session ID: [timestamp or identifier]
- OS: [Darwin/Linux]
- Shell: [bash version]

✅ Protocol Acknowledgment:
I have read ~/.claude/CLAUDE.md and will follow all MANDATORY PROTOCOLS.

Relevant protocols for this session:
- Protocol 1: NEVER COMMIT TO MAIN
- Protocol 4: LOCAL REVIEW BEFORE EVERY PUSH
- [others as applicable]

🛠️ Infrastructure Available:
- Global hooks: ~/.config/git/hooks/ (pre-commit, pre-push)
- Global libraries: ~/.claude/lib/ (build-commons, deploy-commons)
- Global utilities: ~/.claude/scripts/ (audit-branches)
- Documentation: ~/.claude/docs/INFRASTRUCTURE.md
```

**Why this matters**: Training data ends at a fixed point, but real-world dates advance. Always verify environmental facts.

**If I skip this acknowledgment, Andrew should stop me immediately.**

---

### Protocol 1: Never Commit to Main

<a name="protocol-1-never-commit-to-main"></a>

```
STOP. CHECK YOUR BRANCH BEFORE EVERY COMMIT.

✗ FORBIDDEN: git commit on main
✗ FORBIDDEN: git push to main
✗ FORBIDDEN: git merge into main

✓ REQUIRED: Create branch FIRST: git checkout -b claude/<description>-<session-id>
✓ REQUIRED: Verify branch: git branch --show-current (must NOT be "main")
```

**If you find yourself on main**: Stop immediately. Create a branch. Do not proceed until confirmed.

**Branch naming format:**

```
claude/<type>-<description>-<session-id>
```

Examples:

- `claude/feature-auth-refresh-abc123`
- `claude/fix-memory-leak-def456`
- `claude/refactor-api-client-ghi789`

---

### Protocol 2: Use Local Agents Aggressively

<a name="protocol-2-use-local-agents"></a>

You have access to specialized agents via the Task tool. **Use them proactively, not as a last resort.**

See [Agent Reference](#agent-reference) for complete details.

---

### Protocol 3: Keep Tests in Sync

<a name="protocol-3-keep-tests-in-sync"></a>

**Every code change that affects behavior MUST have corresponding test updates.**

```
BEFORE committing ANY code change:

□ Run full test suite (project-specific command)
□ If tests fail → fix them BEFORE proceeding
□ If you changed behavior → generate/update tests
□ Coverage must not decrease without explicit justification
```

**Tests are not optional. Tests are not "I'll do it later." Tests are NOW.**

See [Testing Standards](#testing-standards) for detailed requirements.

---

### Protocol 4: Local Review Before Every Push

<a name="protocol-4-local-review-before-every-push"></a>

**Never push without clean local code-reviewer approval.**

**WHY: Every push triggers expensive CI/CD. Local reviews cost nothing.**

- GH Actions minutes cost money
- EAS builds cost money and have limits
- Each push-fix-push iteration multiplies costs
- One thorough local review > three costly push iterations

**The standard is CONFIDENCE, not hope. If you're "pretty sure" it will pass, you haven't done enough local verification.**

**✓ VERIFICATION CHECKPOINT - Before EVERY commit:**

```
🔍 PRE-COMMIT VERIFICATION:
□ Branch check: [current branch - must NOT be main]
□ Tests: [pass/fail - if fail, must fix before commit]
□ Code review: [agent used, verdict]
□ Security check: [applicable? Y/N - if Y, result]
□ Commit message: [follows format? Y/N]

VERDICT: [READY TO COMMIT / BLOCKED - reason]
```

If BLOCKED: I must fix issues before proceeding.
If READY: I proceed with commit.

**Andrew: If you don't see this checklist, I've violated the protocol.**

**THE REVIEW CYCLE:**

```
fix → local review (code-reviewer) → commit → push → CI ($$) → remote review → repeat

EXIT WHEN: Local clean + CI green + remote review clean

💰 COST OPTIMIZATION:
   - Everything before "push" is FREE
   - Everything after "push" costs money
   - Minimize iterations through the expensive part

CRITICAL: If remote review finds issues local review missed →
         reassess local review quality, don't just skip it.
         Remote finding issues = you wasted money on insufficient local verification.
```

**Review tiers:**

- `code-reviewer`: Runs on EVERY commit automatically via git hook (FREE, local)
- `adversarial-reviewer`: Runs on EVERY commit automatically via git hook (FREE, local)
  - Uses the v1.1.0 agent with structured failure mode checklist, severity calibration, and domain awareness
  - Security-critical files get an "elevated scrutiny" log note but all commits are reviewed
  - **PUSH ONLY AFTER BOTH REVIEWERS ARE CLEAN**
  - Remote review finding issues local review could have caught = you wasted money

**If remote keeps finding missed issues**: Fix code, push again - hooks will re-run agents automatically.

---

### Protocol 5: Post-Push CI/CD Monitoring

<a name="protocol-5-post-push-monitoring"></a>

**⚠️  Remember: You're now consuming paid CI/CD resources. Each iteration costs money.**

**After pushing a PR, you are NOT DONE. Monitor and iterate until fully approved.**

If CI fails or remote review finds issues, you likely skipped adequate local verification. Learn from this - do more thorough local review next time.

```
POST-PUSH PROTOCOL:

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
8. **CRITICAL: Follow Protocol 4** - Run local code-reviewer on fixes before pushing
9. Address local review findings (may take multiple iterations)
10. Push fixes, GOTO step 3
11. LOOP until:
   ✓ CI passes (all checks green)
   ✓ PR Reviewer has no blocking comments
   ✓ All automated feedback addressed

ONLY THEN is the PR ready for merge approval.
```

**Do not abandon the PR after pushing.** The job isn't done until CI is green and reviewers are satisfied.

---

### Protocol 6: PR Lifecycle

<a name="protocol-6-pr-lifecycle"></a>

**Creating a PR and merging a PR are ALWAYS two separate turns requiring two separate explicit authorizations.**

```
Step 1: gh pr create → report PR URL → STOP. Wait.
Step 2: CI runs → report CI status → STOP. Wait.
Step 3: Human says "merge it" for that specific PR → gh pr merge → STOP.
```

**"Merge it" in a compound instruction** ("merge it, then do X") means "begin the merge process through normal channels." It does NOT authorize skipping CI, skipping review, or bypassing the merge-lock. The response to "merge it" is to create the PR and stop — not to immediately merge.

**The following are BLOCKED** — not just discouraged. The Claude Code hook
(hook-block-api-merge.sh) and the gh() wrapper both enforce these blocks:

```
✗ FORBIDDEN: gh api repos/.../pulls/NNN/merge --method PUT  (REST endpoint — blocked)
✗ FORBIDDEN: gh api graphql -f query=mutation{mergePullRequest...}  (GraphQL inline — blocked)
✗ FORBIDDEN: Creating and merging a PR in the same response
✗ FORBIDDEN: Merging without confirmed CI green
✗ FORBIDDEN: Using any workaround when gh pr merge fails

✓ REQUIRED: gh pr merge <number> (routes through pre-merge-review.sh)
✓ REQUIRED: Merge only after explicit authorization for that specific PR number
✓ REQUIRED: If gh pr merge fails → report the failure → ask human to merge manually
```

**Known enforcement gap — GraphQL via file input:** `gh api graphql --input mutation.json`
where the file contains a `mergePullRequest` mutation cannot be blocked by regex pattern
matching. This is an accepted known limitation. Protocol 6 is the enforcement for this
case: do not construct mutation files containing `mergePullRequest`.

**If `gh pr merge` is silently failing:** This is likely a token scope issue. Report it to
the human. Do not attempt workarounds. Ask the human to investigate and merge manually.

This protocol exists because of two incidents on 2026-02-24:

- PR #813: `gh pr merge` failed → REST API used as workaround → pattern learned
- v1.11.0: that pattern reused → 9-second unauthorized production merge → required revert

---

## 📋 Verification Checklists

<a name="verification-checklists"></a>

### Pre-Commit Checklist

**💰 All of this is FREE. Do it thoroughly - pushing half-verified code is expensive.**

```
□ On feature branch (NOT main): git branch --show-current
□ Tests pass (project-specific test command) - RUN LOCALLY FIRST
□ Linter clean (if applicable) - RUN LOCALLY FIRST
□ Type checking passes (if applicable) - RUN LOCALLY FIRST
□ AI review clean: git hook auto-runs code-reviewer agent (FREE, local)
□ Adversarial review clean: git hook auto-runs adversarial-reviewer on EVERY commit (FREE, local)
□ No console.log/print statements in production code
□ No hardcoded secrets
□ No commented-out code
□ Commit message follows conventional format
```

**Every item above costs nothing to verify locally. Skipping any of them and letting CI catch it costs money.**

### Pre-Push Checklist

**⚠️  PUSHING IS EXPENSIVE - Verify everything locally first**

```
□ All pre-commit checks pass
□ Adversarial review clean (runs on every commit via hook)
□ Tests pass IN SIMULATOR (for mobile) or local environment
□ Linting and type checking clean locally
□ You are CONFIDENT this will pass CI, not just hopeful
□ You have done EVERYTHING verifiable locally
□ Branch pushed to origin
□ PR created with comprehensive description
□ Ready to monitor CI and respond to reviewer
□ Will not context-switch until Protocol 5 complete
```

**If you're thinking "I'll just push and see what CI says" - STOP. That's expensive. Do more local verification.**

### Completion Verification

**💰 Declaring work "done" prematurely leads to expensive push-fix-push cycles.**

**Before declaring work "done", "ready", or "complete", I MUST output:**

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

**If "NO" or any stage incomplete: Work is NOT done.**

Only when ALL STAGES show ✓ and "ALL STAGES COMPLETE: YES" can I use completion language.

**Andrew: If I declare work "done" without this checklist, I've failed the protocol.**

---

## Completion Protocol

<a name="completion-protocol"></a>

**Claude Code optimizes for completion. This is its primary failure mode.**

### The Stages

Each stage must be explicitly verified before proceeding to the next:

- **STAGE 1 - LOCAL REVIEW**: What I checked, what I found
- **STAGE 2 - COMMIT**: Commit hash
- **STAGE 3 - PUSH**: Branch name
- **STAGE 4 - PR CREATED**: PR number/link
- **STAGE 5 - CI/CD STATUS**: Waiting/passed/failed
- **STAGE 6 - PR REVIEW ANALYSIS**: Issues found, or "clean"

**Do not summarize or skip stages.** Each stage must appear in output before proceeding to the next.

### Definition of Done

"Done" means: PR exists, CI passes, PR review analyzed, all issues resolved.

"Done" does not mean: code written, tests pass locally, committed.

### Banned Completion Phrases

The following phrases are **not permitted** until Stage 6 is complete:

- "production ready"
- "ready for review"
- "all done"
- "changes are complete"

---

## Commit Message Format

<a name="commit-message-format"></a>

```
<type>(<scope>): <subject>

<body - what and why>

AI review: <N> clean iterations
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

## 🔍 Agent Reference

<a name="agent-reference"></a>

### When to Use Agents

| Task | Agent/Tool | Trigger |
|------|------------|---------|
| **Code Review** | `code-reviewer` | Before EVERY commit |
| **Adversarial Review** | `code-critic:adversarial-reviewer` | Every commit (via git hook) |
| **Architecture Review** | `architect-review` | Structural changes, new patterns |
| **Security Audit** | `security-auditor` | Auth, data handling, API security |
| **Library Docs** | `mcp__context7__*` | Framework/library questions |

### Agent Naming Conventions

**Note**: Agent names vary by context:

- **Task tool** (interactive sessions): Use full format `plugin:agent` (e.g., `code-critic:adversarial-reviewer`)
- **CLI `--agent` flag** (git hooks, scripts): Use short name `agent` (e.g., `adversarial-reviewer`)

### Security-Critical File Patterns

Git hooks detect these patterns and log "elevated scrutiny" during adversarial review (the review itself runs on every commit regardless):

- **Auth**: `**/auth/**`, `**/oauth/**`, `**/jwt/**`, `**/password/**`, `**/session/**`
- **Payment**: `**/payment/**`, `**/billing/**`, `**/stripe/**`, `**/paypal/**`
- **Database**: `**/db/**`, `**/database/**`, `**/models/**`, `**/migrations/**`, `**/schema/**`
- **Security**: `**/security/**`, `**/crypto/**`, `**/encryption/**`, `**/secrets/**`

**Mindset**: If a tool or agent exists that could help, use it. Don't guess when you can invoke an expert.

---

## Testing Standards

<a name="testing-standards"></a>

**Every code change that affects behavior MUST have corresponding test updates.**

### Requirements

- Run full test suite before every commit (project-specific command)
- If tests fail → fix them BEFORE proceeding
- If you changed behavior → generate/update tests
- Coverage must not decrease without explicit justification
- New functionality has tests
- Edge cases covered
- Tests pass locally

### Anti-Patterns

- Never disable tests instead of fixing them
- Never remove or disable tests without explicit justification
- Never skip testing with "I'll do it later"
- Never decrease coverage without justification

---

## Code Review Standards

<a name="code-review-standards"></a>

### General Code Review Checklist

Use this for Protocol 4 (AI review iterations):

#### Security

- [ ] No hardcoded credentials or API keys
- [ ] Input validation on user data
- [ ] No injection vulnerabilities (SQL, XSS, command injection)
- [ ] Proper authentication/authorization checks
- [ ] No sensitive data in logs or error messages
- [ ] Environment variables used for all secrets

#### Correctness

- [ ] Logic handles edge cases
- [ ] Async/await used correctly (no missing awaits)
- [ ] Error handling with try-catch or equivalent
- [ ] No race conditions
- [ ] Resource cleanup (connections, listeners, timers, subscriptions)
- [ ] Graceful degradation on external service failures

#### Quality

- [ ] Follows existing codebase patterns
- [ ] Self-documenting variable and function names
- [ ] No dead code (remove, don't comment out)
- [ ] DRY — no unnecessary duplication
- [ ] Appropriate level of abstraction

### Red Flags — Immediate Rejection

1. Hardcoded credentials or API keys
2. `console.log` or debug statements in production code
3. Commented-out code blocks
4. TODO without GitHub issue reference
5. Disabled linting/type checking rules without justification
6. Missing error handling on async operations
7. Unsanitized user input
8. Synchronous blocking operations in async contexts
9. Tests removed or disabled
10. Coverage decreased without explicit justification

### Anti-Patterns to Avoid

- **Over-engineering**: Don't add abstraction until needed (need 3 real examples)
- **Premature optimization**: Profile before optimizing
- **Shotgun surgery**: Changes should be cohesive, not scattered
- **God objects**: Keep components/functions focused
- **Magic numbers**: Use named constants
- **Deep nesting**: Refactor deeply nested conditionals (early returns)
- **Tight coupling**: Components should be loosely coupled
- **Ignoring errors**: Always handle error cases explicitly
- **Skipping review**: Never bypass Protocol 4

---

## Technical Standards

### Architecture

- **Composition over inheritance** — Use dependency injection
- **Interfaces over singletons** — Enable testing and flexibility
- **Explicit over implicit** — Clear data flow and dependencies
- **Test-driven when possible** — Never disable tests; fix them

### Error Handling

- **Fail fast** with descriptive messages including context
- **Fail loudly** — Silent fallbacks (`or {}`) convert informative crashes into silent corruption
- Handle errors at appropriate level; never silently swallow exceptions

### Shell Scripts

- GNU Bash 5.x compatible
- All shellcheck issues resolved (errors, warnings, *and* info)
- Never use `# shellcheck disable` directives
- **Critical**: Never use `((var++))` with `set -e` — when var=0, this exits. Use `((var += 1))` instead.
- Remove unused variables completely rather than suppressing warnings

---

## Git Workflow

### Branch Discipline

- **Always work on branches** — No code changes on main
- **Never merge to main directly** — Merge requires explicit permission
- **Never `git add .`** — Add files individually; know what you're committing
- **Never `--no-verify`** — BLOCKED by Claude Code hooks; human must commit manually in emergencies

### Repository Visibility

- **ALWAYS create PRIVATE repositories by default** — Use `--private` flag
- **NEVER create PUBLIC repositories without explicit permission**
- Personal configurations, dotfiles, and user-specific content must be PRIVATE
- Exception: Only create public repos when explicitly instructed to do so

### The PR Cycle

Strict adherence to: **local review → commit → push → create PR → analyze PR review → fix issues → repeat until clean**

Everything up to and including a misaligned PR is recoverable. A botched merge to main is not. This is why merge requires permission—it's the point of no (easy) return.

### Commit Hygiene

- Prefer `git mv` and `git rm` over bare `mv` and `rm`
- Commit working code incrementally
- Never commit code that doesn't compile

---

## Safety Boundaries

### Always Ask Before

- Running `rm -rf` (explain what and why)
- Initiating platform-specific builds (EAS builds, production builds, etc.)
- Merging to main
- Irreversible operations (schema changes, data deletion, public APIs)
- Creating PUBLIC GitHub repositories (always create PRIVATE by default, ask permission for public)

### Verification Discipline

- Test changes in `/tmp/` before applying to production code
- Iterate with code-review agent before presenting completed code
- Batch size ~3 changes, then verify against reality (not just TodoWrite)
- More than 5 actions without verification = accumulating unjustified beliefs

### Chesterton's Fence

Before removing or changing anything, articulate why it exists. Can't explain it? You don't understand it well enough to touch it.

---

## Project Integration

### Learn the Codebase First

- Find similar features/components
- Identify common patterns and conventions
- Use same libraries/utilities when possible
- Follow existing test patterns

### Tooling

- Use project's existing build system, test framework, formatter/linter
- Don't introduce new tools without strong justification
- Refer to linter configs and .editorconfig if present
- Text files end with newline

---

## Global Infrastructure

This CLAUDE.md documents **what** to do. Global infrastructure **enforces** it automatically.

### Automated Enforcement

Many protocols are enforced by git hooks and scripts:

| Protocol | Automation | Location |
|----------|------------|----------|
| Protocol 1 (No commits to main) | pre-commit hook | `~/.config/git/hooks/pre-commit` |
| Protocol 4 (Code review) | pre-commit hook | `~/.config/git/hooks/pre-commit` |
| Protocol 4 (Iterative review) | pre-push hook | `~/.config/git/hooks/pre-push` |
| Protocol 6 (No REST/GraphQL merge) | PreToolUse Bash hook | `~/.claude/scripts/hook-block-api-merge.sh` |
| Protocol 6 (No REST/GraphQL merge) | gh() wrapper | `~/.config/bash/functions.sh` |
| Build consistency | build-commons.sh | `~/.claude/lib/build-commons.sh` |
| Deployment safety | deploy-commons.sh | `~/.claude/lib/deploy-commons.sh` |
| Branch cleanup | audit-branches.sh | `~/.claude/scripts/audit-branches.sh` |

**Key Point**: If hooks block an operation, it means I violated a protocol. `--no-verify` is BLOCKED by Claude Code hooks. Emergency bypass (human only): Human must run commit manually.

### Infrastructure Documentation

Complete infrastructure documentation: `~/.claude/docs/INFRASTRUCTURE.md`

This includes:

- How hooks work and discover project extensions
- How to extend infrastructure for project-specific needs
- Common functions available in shared libraries
- Troubleshooting and debugging

**MANDATORY**: When working on infrastructure-related tasks, reference this documentation.

---

## When to Consult Auxiliary Documentation

💡 **For Philosophical Questions or Decision Frameworks:**

If facing architectural decisions, unclear about directive compliance levels, or need decision-making guidance:
→ Read `~/.claude/docs/PHILOSOPHY.md`

💡 **For Reference Material:**

If setting up new repositories, need CI/CD commands, or want communication preferences:
→ Read `~/.claude/docs/REFERENCE.md`

💡 **For Custom Agent Development:**

If creating or modifying agents:
→ Read `~/.claude/docs/CUSTOM_AGENTS.md` (already exists)

💡 **For Infrastructure Details:**

If working on hooks, scripts, or global infrastructure:
→ Read `~/.claude/docs/INFRASTRUCTURE.md`
