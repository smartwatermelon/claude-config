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
| Protocol 4 (Code review) | commit-msg hook (calls `run-review.sh`) | `~/.config/git/hooks/commit-msg` |
| Protocol 4 (Full-diff review) | pre-push hook | `~/.config/git/hooks/pre-push` |
| Protocol 6 (No REST/GraphQL merge) | PreToolUse Bash hook | `~/.claude/scripts/hook-block-api-merge.sh` |
| Protocol 6 (No REST/GraphQL merge) | gh() wrapper (sourced by `functions.sh`) | `~/.config/bash/gh-wrapper.sh` |
| Protocol 6 (Off-org PRs forced draft) | gh-wrapper.sh | `~/.config/bash/gh-wrapper.sh` |
| Restricted gh tokens (no keyring fallback) | PreToolUse Bash hook + gh-wrapper.sh | `~/.claude/scripts/hook-block-gh-auth.sh`, `~/.config/bash/gh-wrapper.sh` |
| Protocol 6 (Merge-lock is human-only) | PreToolUse Bash + Write/Edit hooks | `~/.claude/scripts/hook-block-merge-lock-authorize.sh`, `hook-block-merge-locks-write.sh` |
| Commit/PR text approval | PreToolUse Bash hook + gh-wrapper.sh | `~/.claude/scripts/hook-block-personify.sh`, `gate-review.sh` |

The pre-commit hook no longer runs AI review. It blocks commits on
main/master, runs the pre-commit framework, and runs `.project-hooks/pre-commit`.
AI review moved to commit-msg so the reviewer can see the commit message.

`build-commons.sh`, `deploy-commons.sh`, and `audit-branches.sh` were listed
here previously. They no longer exist in claude-config or dotfiles.

**Key Point**: If hooks block an operation, it means a protocol was violated. `--no-verify` is BLOCKED by Claude Code hooks. Emergency override (human only): Human must run commit manually.

**When a hook blocks your commit**: Go back and rework the code — do not ask the human to override. See CODE-REVIEW.md § "When Reviews Find Issues — Rework, Don't Override" for the full escalation ladder. Only after 3+ genuine rework attempts with no viable path forward should you present the findings and ask if the human wants to override.

---

## Deployment (#453)

`~/.claude` links into a deploy clone, never into the working checkout.

| Path | Role | Who writes it |
|------|------|---------------|
| `~/Developer/claude-config` | working checkout | agents and Andrew: edit, branch, pull |
| `~/.local/share/claude-config` | deploy clone, on `origin/main` | only `claude-config-deploy.sh`, outside Claude Code |
| `~/.claude/**` | symlinks into the deploy clone | the clone's `install.sh` |

Before this, `~/.claude` linked into the working checkout, so a mid-edit hook
or a branch switch there became the hook set every session ran (#453). The
clone also sits outside the sandbox's writable paths, so the sandbox's
protected-path rule for `CLAUDE.md` no longer blocks agents from pulling the
working checkout.

**The deploy job.** `scripts/claude-config-deploy.sh` (on `PATH` as
`claude-config-deploy`, linked straight to the clone's copy):

1. Takes a lock (`~/.local/state/claude-config/deploy.lock`, a symlink naming
   the holder's pid; a dead holder's lock is removed). Exit 3 if held.
2. Refuses (exit 2, logs, notifies once per new problem, changes nothing) when
   the clone is missing, off `main`, has tracked changes, or cannot
   fast-forward.
3. Fetches origin over anonymous HTTPS. The repo is public, so launchd needs
   no SSH agent or key. A failed fetch logs and exits 1 without a
   notification (an offline laptop is normal).
4. `git merge --ff-only` to `origin/main`. Never `reset --hard`.
5. Runs the clone's own `install.sh --sync` when main moved, when
   `~/.claude/hooks/run-review.sh` does not link into the clone, or always on
   a manual run.

The LaunchAgent `com.smartwatermelon.claude-config-deploy` runs
`deploy --scheduled` every 600 s and at load. `bootstrap` generates its plist
(no tracked plist copy) and `uninstall` removes it, the lock-sync pattern.
A user with no GUI login has no `gui/<uid>` domain to load it into
(`launchctl print gui/<uid>` exits non-zero; TILSIT returned 125), so there
`bootstrap` adds a crontab entry instead: every 10 minutes, tagged
`# com.smartwatermelon.claude-config-deploy`, other entries kept. Bootstrap
keeps exactly one of the two and removes the other.
`CLAUDE_CONFIG_SCHEDULER=cron|launchd` overrides the choice. A `crontab -l`
failure other than "no crontab" stops the cron path before any write.
Log: `~/.local/state/claude-config/deploy.log`; launchd's own stdout and
stderr go to `~/.local/state/com.smartwatermelon.claude-config-deploy.log`.

**Deploy health.** A refusal notifies only once, and a LaunchAgent that has
stopped writes nothing, so neither can depend on a notification being seen.
Two state files back persistent indicators, shown only while the deploy clone
exists:

- `~/.local/state/claude-config/deploy.problem` holds the last refusal's key
  (`dirty`, `diverged`, `install-failed`, ...). A good run removes it. The
  status line shows a red `[DEPLOY: <key>]`.
- `~/.local/state/claude-config/deploy.ok` holds the epoch of the last run
  that ended up to date, deployed, or kept dev mode (written atomically). A
  failed fetch, a refusal, or a failed install does not write it. When it is
  missing or older than 2 hours (`CLAUDE_CONFIG_DEPLOY_STALE_HOURS`), the
  status line shows a red `[DEPLOY stale <age>]` (`3h`, `2d`, `never`).

A problem is more specific, so it replaces the stale segment. SessionStart
prints the matching notice on stdout (for the model) and stderr (for the
human). `claude-config-deploy status` shows the last good run time.

**Dev mode.** `~/Developer/claude-config/install.sh --dev` links `~/.claude`
to the working checkout and writes `~/.local/state/claude-config/dev-mode`
(`path=`, `since=`). It shows in three places: a red `[DEV hooks]` at the
start of the status line, a SessionStart notice (stdout, so the model sees
it), and a line in the deploy log on every scheduled run. The scheduled run
keeps dev mode for 12 hours (`CLAUDE_CONFIG_DEV_TTL_HOURS`), still
fast-forwarding the clone, then redeploys `main` and notifies. Reason: an
unrelated merge must not swap hooks out from under a test in progress, but a
forgotten dev mode must not outlive the day. A manual `claude-config-deploy`
ends it at once. If `~/.claude` is off the clone with no marker (for example,
an old `install.sh --sync` from the working checkout), the next scheduled run
relinks it.

**The working checkout hands off.** Once the clone exists, the working
checkout's `install.sh` runs `claude-config-deploy` for `--sync` and a full
install, and the clone's `install.sh` for `--repair` and `--dry-run`, passing
the exit status back. Only `--dev` links the working checkout. So every old
"run `~/Developer/claude-config/install.sh --sync`" instruction, and the
dotfiles `allup` and `dotclaude` functions, deploy `main` instead of quietly
undoing the clone. If the clone has no deploy script it refuses (exit 1). The
clone's `install.sh` refuses `--dev`.

**Repair and audit.** `update-tools.sh` runs the clone's `install.sh
--repair`, or skips repair in dev mode. In the clone, `--repair` no longer
copies a regular file at a link path back into the repo (that would leave the
clone dirty and stop every deploy). It backs the file up to
`~/.claude/backups/symlink-migration/`, copies it unstaged into the working
checkout, and relinks. It skips that copy when the working-checkout file has
uncommitted changes or is untracked. So a live edit that replaced a link
(Claude Code writing `settings.json`, for example) is reverted in `~/.claude`.
It survives as a working-checkout diff to commit or, when the copy was
skipped, only in the backup. An edit written through the link
lands in the clone instead; the next deploy then refuses and notifies until it
is moved to the working checkout. `--learn` still writes the working
checkout's `scripts/known-runtime.txt`, which is where a commit can come from.

**Atomicity.** `git merge --ff-only` rewrites each changed file in turn, so for
the time it runs (not measured; a handful of small files) a hook can see an old file next to a new one, or
a changed file briefly missing (`hook-block-all.sh` then blocks that one Bash
call). A file a pull adds has no `~/.claude` link until the `install.sh
--sync` that follows, seconds later; that includes a new `REQUIRED_HOOKS`
entry, so the #660 lockout lasts seconds instead of until someone runs
`--sync`. The old window was every edit and every branch switch, for as long
as it lasted. A staging clone with a symlink swap would close the gap; it is
not built.

**Bootstrap** (once per machine, in a terminal):
`~/Developer/claude-config/scripts/claude-config-deploy.sh bootstrap`. It
clones over HTTPS if the clone is missing, re-runs itself as the clone's copy,
deploys, links `~/.local/bin/claude-config-deploy`, and loads the agent. It is
idempotent, and refuses without changes if the clone path is not a git clone
or the command path is a regular file. `claude-config-deploy status` reports
the clone, the link mode and the agent.

---

## Claude Code Tool Hooks

Configured in `settings.json` under `hooks`. The status-line `cc-status`
entries are omitted here.

| Event / matcher | Script |
|-----------------|--------|
| PreToolUse `Bash` | `~/.claude/scripts/hook-block-all.sh` (chain below) |
| PreToolUse `Write`, `Edit` | `hook-block-merge-locks-write.sh`: blocks writes into `merge-locks/`, `gate-review/`, and personify's `checks/` and `stamps/`, and to `gate-rules.conf`, `copy-paths.conf` and personify's `route-command` |
| PreToolUse `EnterWorktree` | `hook-block-enter-worktree.sh` |
| PostToolUse `Bash\|Read` | `hook-redact-secret-output.py`: redacts env secret values, gitleaks findings, vendor prefixes gitleaks lacks, and the whole stdout of credential-printing commands (`op read`, `security -w`, ...) |
| UserPromptSubmit | `hook-gate-inline-approve.sh`: a prompt `approve <code>` approves the staged gate text with that code (text gate, below) |
| UserPromptSubmit | `hook-review-override.sh`: a prompt `override <code>` lets that exact blocked diff through within 30 minutes, once at best effort (`CODE-REVIEW.md`, Andrew's override) |
| Stop, SubagentStop | `hook-budget-guard.sh` |

`hook-block-all.sh` runs these in order and stops at the first block:

1. `hook-block-secret-leak.sh` (first on purpose: the others log the full command when they block). Also denies 1Password forms that print whole items: `op item get` with `--format json`, `--reveal`, `--fields` or `--otp`, `op document get` without `--out-file`, and `op item list --format json` piped into `op item get`. Use `op read op://vault/item/field` instead (#731)
2. `hook-block-gate-dir-write.sh` (Bash-path writes into `merge-locks/`, `gate-review/` (which holds `review-overrides/`), and personify's `checks/` and `stamps/`, and to `gate-rules.conf`, `copy-paths.conf` and personify's `route-command`; also agent runs of either chat approval hook)
3. `hook-block-no-verify.sh`
4. `hook-block-short-no-verify.sh`
5. `hook-block-main-commit.sh`. Denies a commit on main/master. Since #792 it also denies a command that moves a repo's primary checkout off its default branch: `git checkout <branch|commit>` (with `-b`, `-B`, `--orphan`, `--detach`, `-`), `git switch` (with `-c`, `-C`, `--orphan`, `--detach`, `-`), `git stash branch` and `gh pr checkout`. The deny names the replacement, `git -C <repo> worktree add --no-track -b <branch> .claude/worktrees/<name> origin/<default>`.
   - Primary checkout: `rev-parse --git-common-dir` equals `--absolute-git-dir`. A linked worktree is never guarded.
   - Repo: the hook input's `cwd`, then any `env -C` and `git -C` values in order. A `-C` from a variable or substitution, an earlier `cd`, or `--git-dir` denies (fail closed). A path that is not a repo passes, since git fails there anyway.
   - Default branch: `refs/remotes/origin/HEAD`, else `main` if it exists, else `master`.
   - Allowed: a switch to the default branch, `git checkout -- <path>`, `git checkout <ref> -- <path>`, `git checkout .`, `-p`, a checkout operand that is not a ref (a path), `git pull` and `git worktree add`.
   - Only real invocations count. A piece of the command is checked only when a command starts there, not in quotes, a heredoc or a comment, so a commit message or `printf` that mentions `git checkout -b` passes.
   - Not covered: `git reset --hard`, `git rebase`, `git bisect`, `bash -c`/`eval` strings, command substitution (`$(...)`, backticks), a command after a single `&`, aliases and variables.
6. `hook-block-personify.sh` (text gate, below)
7. `hook-check-commit-message.py`
8. `hook-block-merge-lock-authorize.sh`
9. `hook-block-api-merge.sh`
10. `hook-block-gh-auth.sh` (`gh auth token|switch|login|logout|refresh|git-credential` and `status -t`: these reach gh's keyring token)
11. `hook-block-git-worktree.sh`

### Text Gate (v3)

Text gate v3 shipped 2026-10-22 in claude-config #771, #772 and #773,
dotfiles #461, and personify #122. Every destination routes to `review` or
`exempt`.
Pangram is out of the gate: no route calls it, and `stage` needs no check
record. A `review` destination needs clean lint plus Andrew's approval. An
`exempt` destination gets lint warnings only.

- Lint: `scripts/gate-lint.sh [--mode block|warn] [--allow RULE --reason
  TEXT]... <kind> <file>` runs personify's `length_check.py` (not for
  `copy`, which has no cap) and then `vale --config prose/.vale.ini` with
  the `prose/styles/Andrew/` style. The `--config` is always explicit: bare
  `vale` walks up past the repo root and runs its defaults. `stage` runs it
  in block mode on every route but `exempt`. A vale error refuses the stage
  unless `--allow <Rule> --reason <text>` accepts it, and the reason shows
  in the approval view. A length cap cannot be allowed. Block mode fails
  closed when `vale` is missing (it is in the dotfiles Brewfile). On an
  exempt destination, `hook-block-personify.sh` runs it in warn mode on the
  message file: findings print, the command runs.
- Approval, by any one channel:
  - Editor: `open` writes the batch buffer and opens it in `GATE_EDITOR`
    (default BBEdit). If `open -a` cannot find that app, it falls back to
    `open -t`, the default text editor. Andrew may edit; the saved text is
    what gets approved.
  - Chat: with no GUI session (`launchctl managername` is not `Aqua`, so
    SSH, cloud or a daemon), `open` prints each staged item with a 6-hex
    `approve-code`, the start of its content hash. The agent shows the text
    and the code. Andrew replies `approve <code>`, and the UserPromptSubmit
    hook `hook-gate-inline-approve.sh` approves the item whose hash matches.
    A restage with other text gets another code, short of a 24-bit prefix
    collision.
  - GitHub draft: on a review route, `gh pr create --draft` and a pending
    `gh api` review (no `event`) pass on clean lint with no approval.
    `gh pr ready` is denied; Andrew clicks Ready for review in the GitHub
    UI. The GraphQL `markPullRequestReadyForReview` mutation is refused by
    `gh-wrapper.sh` (`~/.local/bin/gh`) in every repo, but not yet by
    `hook-block-personify.sh`; gate v3 PR 4 (landing) adds it there. The
    dotfiles pre-push hook checks text added to a ready (non-draft)
    Beacon PR against gate-review approval.
- `scripts/gate-review.sh stage --kind <kind> <name> <file>` queues text.
  `--kind` is required: `commit`, `pr`, `issue`, `line-comment`,
  `pr-comment`, `code-comment` or `docstring`. `open` shows the batch and
  waits. Each batch gets its own file,
  `batches/<repo>-<branch>-<nonce>.txt`, removed once approved. Any other
  exit keeps it, and the next `open` for the same items starts from it;
  `open` removes buffers untouched for a day (`GATE_REVIEW_BUFFER_TTL`,
  seconds). Approval is changing `# STATUS: PENDING` to
  `APPROVED` and saving. `ABORT` revokes only that batch's own items.
  `check <file>` exits 0 if the file matches any approval. `check --kind
  <kind> <file>` also measures the file against that kind's cap (not on
  `exempt`); without `--kind` there is no length check.
- The personify directory comes from `gate-review.sh personify-path`: the
  local install in `installed_plugins.json`, else the claude.ai synced copy.
  A missing personify, a missing `length_check.py`, or a checker error
  (exit 5) refuses, and the message says it is a checker error.
- Staged and approved text is kept per caller's repo and branch, taken from
  the current directory: `pending/<repo>-<branch>/<name>` and
  `approved/<repo>-<branch>/<name>` (`batch` outside a repo). `open` batches
  only its own key's items, and prints an `approved: <path>` line for each
  item it approved; commit or post from that path. Run `stage` and `open`
  from the same directory. ABORT, a timeout, or a killed wait leaves the
  items staged under their key, and the batch header says so. Two sessions in
  the same directory share one key. `check` still matches by content hash
  across every key, so `git -C <repo> commit` from elsewhere passes.
- Upgrade from the flat layout: items left directly in `pending/` are never
  batched or approved, and every `open` names them; restage any still
  wanted. Approvals left directly in `approved/` still verify until their
  30 minutes run out.
- `check` compares a content hash. A match is not consumed, so an identical
  repeat (for example a retry after a failed push) passes. Approvals expire
  30 minutes after they are written (`GATE_REVIEW_APPROVAL_TTL`, seconds),
  the same window as a merge-lock; `check` and `stage` delete expired ones.
- Text must come from a file at an absolute path: `git commit -F` or
  `gh ... --body-file`. Inline `-m`/`--body`, relative paths, and `~`/`$VAR`
  paths are blocked. PR and issue titles need no visual approval; they get
  a length check only. The hook reads `-t`, `--title` and `--title=` on
  `gh pr|issue create|edit` and runs the checker on the value. A title it
  cannot measure (`$`, a backtick, a glob, attached `-t<value>`, or two
  title flags) is denied. The hook measures titles through
  `gate-review.sh measure --kind <kind> --title <value> [--repo R] [--dir D]
  </dev/null`, the same checker path `stage` and `check` use. Like the
  rest of the length check, it skips an `exempt` destination. Routing only
  relaxes, so when the hook cannot pin the destination down (any `cd` in
  the command, or a destination the body check would deny), the title is
  measured without routing.
- The hook derives the length kind from the command, not from `stage`:
  `git commit` is `commit`; `gh pr create|edit` is `pr`; `gh issue
  create|edit` is `issue`; `gh pr comment`, `gh issue comment` and `gh pr
  review` are `pr-comment`; `gh api` to `pulls/<n>/comments` is
  `line-comment`, and any other `gh api` body is `pr-comment`. A text
  staged under one kind and published as another is measured again.
- Gated surfaces: `git commit`; `gh pr create|comment|edit|review` and
  `gh issue create|comment|edit` when they carry a body flag; `gh api` when
  it sends a `body` field or a GraphQL mutation with a `body:` argument. The
  one verifiable `gh api` form is `-F body=@/absolute/path`. Not gated:
  `gh api --input <json>`, `git tag -m`, `git notes`, `gh release --notes`.
  A follow-up PR (gate v3 PR 4, landing) adds more `gh` forms and blocks
  the GraphQL ready-for-review mutation; this list changes when it merges.
- The hook joins backslash-continued lines before it checks a command, so a
  body flag on a continuation line is gated with its verb. It does not join
  inside single quotes, heredoc bodies, or comments, where bash does not
  either or where the text is prose.
- `hook-check-commit-message.py` reads the summary from the file named by
  `git commit -F <absolute path>` as well as from `-m`, so commits made
  through the gate still get the conventional-commits pre-flight.
- Enforced by `hook-block-personify.sh` for the Bash tool, and by
  `gh-wrapper.sh` (`_gh_wrapper_approval_gate`) for manual `gh` calls.
- `personify-path` uses the `installPath` of `personify@personify` from
  `~/.claude/plugins/installed_plugins.json`, not a directory picked from
  the plugin cache: the cache keeps every past version, and an old one can
  lack features (2.0.1 had no Keychain key lookup, which the since-retired
  Pangram check needed on 2026-09-24).
  The marker is `scripts/length_check.py`. With no local install, it names
  the copy synced from claude.ai under `~/.claude/plugins/synced/<bucket>/`,
  picking the directory (`personify` or `personify~g<generation>`) from
  that bucket's `manifest.json`. personify and pr-review load from claude.ai
  sync on purpose, to dogfood the upload path; they are not in
  `enabledPlugins`.
- Updating a synced plugin: each CLI start syncs once in the background
  (Claude Code docs, plugins/loading, "Sync timing in terminal sessions").
  A sync that lands after the session started prints `Plugins changed. Run
  /reload-plugins to activate.`; run `/reload-plugins` or start a new
  session. Marketplace commands do not apply: a synced plugin loads as
  `<name>@synced` with no marketplace and no install record. Disable one with
  `claude plugin disable <name>@synced`. The docs say a restart loads the new
  copy, but on 2026-09-30 a restart kept personify 2.0.4 after 2.1.0 synced,
  and only `/reload-plugins` loaded it (#644). If the version looks stale,
  run `/reload-plugins` first. MIMOLETTE has no claude.ai sync, so its
  personify is a CLI install that updates only via `claude plugin update`.
- `gate-rules.conf` (repo root, linked by `install.sh` to
  `~/.claude/gate-rules.conf`) maps each destination to `review` or
  `exempt`; `scripts/gate-route.sh` reads it. Any other outcome, including
  the retired `pangram` and `visual`, is a load error, so the gate fails
  closed. A private `andrewmrich` repo is exempt and a public one is review;
  a failed visibility lookup counts as review. Whoever can edit it can
  exempt a destination from approval, so both write hooks block writes to the
  deployed path `~/.claude/gate-rules.conf`. Reads pass. The hooks match the
  literal path and do not resolve symlinks, so the repo copy stays editable
  through a reviewed PR, and a merged change reaches `~/.claude` on the next
  deploy (within 10 minutes; see Deployment).
- `copy-paths.conf` (repo root, linked to `~/.claude/copy-paths.conf`, guarded
  by both write hooks the same way) lists each repo's public-facing copy:
  `<owner/name> <include|exclude> <glob>`. A `public=*` line applies to every
  github.com repo that `gate-route.sh is-private` does not prove private
  (unknown counts as public), with case-insensitive globs; the shipped
  `public=* include **/README*` gates READMEs in public repos, except vendored
  copies (`**/vendor/**`, `**/third_party/**`, `**/node_modules/**`). On
  every agent `git commit`,
  `hook-block-personify.sh` runs `scripts/gate-copy.py extract` on the
  destination checkout. When staged changes touch a listed path, the added or
  changed text (whole text for a new file; HTML and Markdown stripped, JSON
  string values only) is written to `~/.claude/gate-review/copy/<sha256>.txt`,
  and the commit is blocked until `gate-review.sh check --kind copy` passes on
  it. The `copy` kind never asks `gate-route.sh`: it is always `review`,
  even where the commit message is exempt, and it has no length cap.
  In a repo with copy paths the hook also blocks `git commit -a/-i/-o/-p`, a
  pathspec, and any other index-changing git command in the same call, since
  it reads the index before the call runs. A repo covered only by `public=*`
  gets those limits only when git shows the call could commit a copy file, and
  only for calls of a fixed shape (cd, git add, git rm, one git commit, pipes
  into tail/head/grep/wc/cat, then commands with no other index-changing git
  command); any other shape gets the full limits. The
  `copy-paths.conf` header has the rule. A missing or malformed conf blocks
  every agent commit; `SUSPENDED` is the escape hatch. In-app JSX strings are
  phase 2 (dev-env#206).
- personify route command. `install.sh` writes
  `${XDG_CONFIG_HOME:-~/.config}/personify/route-command`, one line naming the
  deployed `gate-review.sh`. personify reads it to ask `gate-review.sh route`
  for a destination's route: its `pangram_check.py` calls Pangram only on a
  literal `pangram` route, which no rule produces since 2026-10-22 (personify
  #122), and its MCP server reads it too. Both write hooks guard the file, so
  an agent cannot repoint it. A personify PR that deletes `pangram_check.py`
  and removes the detector check from the MCP server is landing; the file,
  its install step and its guards stay until nothing in personify reads it.
- personify `checks/` and `stamps/` hold records from the retired Pangram
  check and human approval stamps. Nothing in the gate reads them now; the
  write hooks still guard both directories.

### Merge-Lock Subcommands

`merge-lock authorize`, its alias `auth`, and `tui` (a bulk picker) all grant
locks. All three are human-only. `hook-block-merge-lock-authorize.sh` blocks
them for agents. Before a merge, `pre-merge-review.sh` asks `merge-lock.sh
policy` for the PR's outcome in `merge-lock-policy.conf` (read from the
claude-config checkout's local main): `lock` needs a valid lock, `exempt` needs
none, and `refuse` stops the merge even with a valid lock. Anything else is
treated as `refuse`: a policy error, an unparseable answer, a missing or
non-executable `merge-lock.sh`, or an unknown repo or PR author. An agent sees
one `[gh] Not merged: ...` line, never the authorize command.

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

## Off-Org Draft-PR Enforcement (gh-wrapper.sh)

`gh pr create` targeting a repo whose owner is not `smartwatermelon`, `nightowlstudiollc`, or `twistedmelonman` is force-created as a draft by `~/.config/bash/gh-wrapper.sh` (symlinked as `~/.local/bin/gh`, and sourced as a bash function via `functions.sh`). This is a mechanical check on the resolved repo owner — not an AI judgement call, and there is no flag or environment variable to opt out. Owner is resolved the same way identity auto-switch resolves it: an explicit `-R`/`--repo` target takes precedence over cwd's `origin` remote.

`twistedmelonman` is the personal account after the 2026-09 org migration (the old personal login `smartwatermelon` was freed up and re-created as the org). All three are in-org for this check; the authoritative list is the `case` in `gh-wrapper.sh`'s draft-forcing block.

**Why**: an automated agent should not be able to open a fully "submitted" PR against a repo outside the orgs this environment is scoped to. The human operator remains free to promote the PR out of draft afterward, at their discretion, via the GitHub UI — the wrapper only governs creation time, not later state. See `smartwatermelon/dotfiles#174` (design) and `#175` (implementation).

**If an agent hits this**: a draft PR on an off-org repo is expected behavior, not a bug. Do not attempt to work around it in any way. Surface it to the user as a draft PR and stop there.

### Known Gaps

- `gh-wrapper.sh` reaches the Bash tool two ways: `settings.json` sets `BASH_ENV` to `~/.config/bash/functions.sh`, which sources it, and it is installed as `~/.local/bin/gh`. It also exports `sugh`, which runs the real `gh` binary and skips ALL wrapper checks (merge guard, draft forcing, approval gate, identity switch). The "no flag to opt out" statement above applies to `gh`, not `sugh`.
- Full bypass list: `docs/2026-09-23-personify-and-gating-overview.md` in smartwatermelon/dev-env.

---

## Review Hooks

### How Review Runs

- `code-reviewer` and `adversarial-reviewer` run on EVERY commit automatically via the commit-msg hook, which calls `~/.claude/hooks/run-review.sh` with the in-progress message
- adversarial-reviewer (code-critic plugin) uses a structured failure mode checklist, severity calibration, and domain awareness
- Models (defaults; override with `git config review.model`, `review.adversarialModel`, `review.arbiterModel`):
  - code-reviewer, commits: Haiku 5.5 or newer when the CLI's `haiku` alias resolves to one, otherwise `claude-sonnet-5-5`. The alias is probed at most once a day; the answer is cached in `~/.claude/cache/review-haiku-alias` (delete it to re-probe). Haiku 4.5 is never used: it made repeated false BLOCKING findings.
  - code-reviewer, `--mode=full-diff` and `--mode=codebase`: `claude-sonnet-5-5`
  - adversarial-reviewer: `claude-sonnet-5-5` in every mode
  - arbiter: `claude-sonnet-5-5`, invoked only when code-reviewer returns a BLOCKING FAIL and adversarial-reviewer returns PASS
- Timeouts: `review.timeout` (default 120s) covers the reviewers and the single-pass arbiter. The chunked-path arbiter reads files, so it has its own `review.arbiterTimeout` (default 300s, or `review.timeout` if larger). When it times out, the per-file block stands and the log line reads `arbiter: FAIL (<file>) - timed out after Ns, no ruling`.
- Size limits: `review.maxLines` (default 1000) is the full-review ceiling; above it, review is chunked per file. Above `review.skipThreshold` (default 2500) the commit is blocked and must be split.
- Attempt limit: `review.maxAttempts` (default 3) caps consecutive blocked commit reviews per branch. At the limit the hook prints a STOP message, and later attempts are refused without review. The refusal still blocks the commit. Any passing commit resets the count. Counters live in `<git-dir>/review-attempts/<branch>`, one set per worktree. A human resets one with the `rm` command that the STOP message prints.
- commit-msg skips review when the subject starts with `fixup!`, `squash!`, `wip:`, `WIP:`, or `wip`/`WIP` followed by whitespace
- The pre-push hook runs one `--mode=full-diff` review that must pass. It files no issues. `--mode=codebase` is weekly/on-demand only (see CHECKLISTS.md, "On-Demand Codebase Review").
- `run-review.sh` has no special path for security-critical files. `is_security_critical` (in `lib-review-issues.sh`) is used only by `pre-merge-review.sh` (those diffs are never summarized) and for the `security` issue label. See REFERENCE.md for the pattern.

### Review Log Verification

After every commit, verify the hook ran by reading the log header:

```bash
head -6 "$(git -C /abs/path/to/repo rev-parse --absolute-git-dir)/last-review-result.log"
```

Check: timestamp within ~60s, repo matches, branch matches, commit matches HEAD.

The global `~/.local/state/claude-review/last-review-result.log` (outside `~/.claude`, which the sandbox denies) is a pointer file with a `log:` field pointing to the per-repo authoritative log.

Each run overwrites that log. When a run blocks (any non-zero exit), a copy is kept in `<git-dir>/review-blocked/<UTC-time>-<mode>.log`. The newest 20 copies are kept.

### Review Timeouts

What a timeout (or agent error) does depends on the path:

- Chunked commit review: a file whose code-reviewer pass timed out is unreviewed, and the commit is blocked as INCOMPLETE (#451).
- Whole-diff commit review, code-reviewer timed out or errored: the commit is blocked. The hook says `Review INCOMPLETE ... commit rejected`, and the log records `code-reviewer: INCOMPLETE (timeout)` (or `(agent error)`) and `review: INCOMPLETE` (#590).
- Whole-diff commit review, adversarial-reviewer timed out or errored: the commit is let through as `Review passed (code-reviewer only ...)`. The log records `adversarial-reviewer: skipped (timeout or agent error)`.
- Full-diff pre-push review: the push is let through, and the hook says `Full-diff review INCOMPLETE`. The log records `full-diff: INCOMPLETE (timeout)`. That branch was not reviewed.

A timeout is never a finding: nothing is filed for it (#172).

To get a real review:

- Retry the commit (transient failures happen)
- Retry once with a longer timeout: `git -c review.timeout=300 commit ...`
- Increase the timeout for good: `git config review.timeout 300`
- Split into smaller commits

The human bypass is `git commit --no-verify` (see `docs/HUMAN-BYPASS.md`). Agents cannot use it.

While a reviewer runs, the hook prints one line to stderr if it has not answered after `review.slowNotice` seconds (default 45), for example `[review] code-reviewer has not responded after 45s — still waiting (timeout at 120s)`. Set `review.slowNotice` to 0 to turn it off. A value at or past `review.timeout` prints nothing.

---

## Settings Rationale

### `useAutoModeDuringPlan: false` (`settings.json:293`)

Disables Claude Code's auto-mode permission classifier while in Plan Mode. Auto mode
normally lets a heuristic classifier silently approve Bash commands it judges
read-only, skipping the permission prompt. Plan Mode's whole point is that nothing
executes until the human reviews and approves the plan — auto-mode's classifier
running underneath it has previously caused the classifier to override Plan Mode with
conflicting "execute immediately" behavior (see upstream Claude Code changelog).
Keeping this `false` means every action during planning stays gated on an explicit
human decision, consistent with this config's broader preference for explicit
checkpoints (Protocol 6's merge-lock authorization, etc.) over auto-approval.

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
