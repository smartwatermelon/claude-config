# Global Infrastructure — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - When working on hooks, scripts, or global infrastructure
> - When troubleshooting hook failures or enforcement blocks
> - When extending infrastructure for project-specific needs

---

## Automated Enforcement

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

**Key Point**: If hooks block an operation, it means a protocol was violated. `--no-verify` is BLOCKED by Claude Code hooks. Emergency bypass (human only): Human must run commit manually.

**When a hook blocks your commit**: Go back and rework the code — do not ask the human to override. See CODE-REVIEW.md § "When Reviews Find Issues" for the full escalation ladder. Only after 3+ genuine rework attempts with no viable path forward should you present the findings and ask if the human wants to bypass.

---

## Protocol 6 — Enforcement Details

### Blocked Merge Paths

The following are blocked by `hook-block-api-merge.sh` and the `gh()` wrapper:

```
✗ gh api repos/.../pulls/NNN/merge --method PUT  (REST endpoint)
✗ gh api graphql -f query=mutation{mergePullRequest...}  (GraphQL inline)
✗ gh api graphql --input <file>  (file-backed mutation; closed 2026-04-18)
✗ gh api graphql --input=<file>  (equals form)
✗ gh api graphql --input -       (stdin)
✗ gh api graphql -F input=@<file>  (-F equivalent)
✗ gh api graphql --field input=@<file>  (--field long form of -F)
✗ gh -R owner/repo pr merge NNN  (global flag prefix)
```

**Only allowed**: `gh pr merge <number>` (routes through pre-merge-review.sh)

### File-Backed GraphQL Mutation Bypass (blocked 2026-04-18)

Previously the `--input <file>` variant of `gh api graphql` could not be inspected at command-line scan time because the mutation body lived in a file or on stdin. That gap is now closed: the hook blocks all `--input` forms (file, `=<path>`, stdin `-`, and `-F input=@file`) with a clear message. The git commit/log/show/diff exemption at the top of the hook allows documentation and commit messages to legitimately reference the pattern without false-positive.

### Global Flag Prefix Bypass (blocked 2026-02-25)

Placing a global flag like `-R owner/repo` before the subcommand (`gh -R owner/repo pr merge NNN`) caused the shell wrapper's positional `$1=='pr'` check to be skipped. Blocked at three layers: the hook regex (anchored to command position), the `gh()` bash wrapper (now parses past known global flags), and `~/.local/bin/gh`.

### Silent `gh pr merge` Failures

Likely a token scope issue. Report to the human. Do not attempt workarounds. Ask the human to investigate and merge manually.

### Historical Context

This enforcement exists because of two incidents on 2026-02-24:

- PR #813: `gh pr merge` failed → REST API used as workaround → pattern learned
- v1.11.0: that pattern reused → 9-second unauthorized production merge → required revert

---

## Review Hooks

### How Review Runs

- `code-reviewer` and `adversarial-reviewer` run on EVERY commit automatically via pre-commit hook
- adversarial-reviewer uses v1.1.0 agent with structured failure mode checklist, severity calibration, and domain awareness
- Security-critical files get an "elevated scrutiny" log note but all commits are reviewed

### Review Log Verification

After every commit, verify the hook ran by reading the log header:

```bash
head -6 $(git rev-parse --git-dir)/last-review-result.log
```

Check: timestamp within ~60s, repo matches, branch matches, commit matches HEAD.

The global `~/.claude/last-review-result.log` is a pointer file with a `log:` field pointing to the per-repo authoritative log.

### Review Timeouts

If review times out:
- Retry the commit (transient failures happen)
- Increase timeout: `git config review.timeout 300`
- Split into smaller commits

---

## Shared Libraries

- `~/.claude/lib/build-commons.sh` — Common build functions
- `~/.claude/lib/deploy-commons.sh` — Common deployment functions

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
