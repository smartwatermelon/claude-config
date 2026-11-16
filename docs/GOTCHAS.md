# Gotchas — Andrew Rich

Situational traps moved out of the always-loaded `CLAUDE.md`. Each one bit a
real session. Read the section that matches the task at hand.

## PATH-shim wrappers — reload the shell before testing

After symlinking a script into `~/.local/bin` that shadows a system binary
(ssh, gh, claude), bash's per-session hash table still points at the old
location, so plain `cmd` silently runs the old binary.

**Why it hides:** `command -v` and `type` read that same hash table and report
the stale path too. Only `which <cmd>` (fresh PATH scan) and `hash -t <cmd>`
(shows what is cached) reveal it.

**How to apply:** have the user run `hash -r` before any functional check, and
debug a "wrapper not running" report by asking for `which` and `hash` output —
never `command -v`.

## Submodules

Never run `git submodule update --remote --merge` with a branch checked out
inside the submodule. It merges `origin/main` into that branch, creating a
commit on no remote; the parent then commits a dirty gitlink that no fresh
clone can resolve.

## `git commit --amend` stray branch

After `git commit --amend`, the pre-commit hook may create a stray branch;
clean up with `git branch -D <stray-branch>` and
`git reset --hard <amended-commit>`.

## `gh pr create` says "must first push"

Wait for the background push task to complete before retrying.

## EnterWorktree inside the sandbox

- Never use the name form (`EnterWorktree(name=...)`). It names branches
  `worktree-<name>` and leaves metadata the sandbox will not let
  `git worktree prune` delete. A hook denies it (#885).
- Since Claude Code 2.1.323 the sandbox blocks commits in a launch-repo
  worktree the session was not started in or given. Other repos' worktrees
  commit without it (verified 2026-11-16 in claude-config). The path form
  gives the session that worktree, so sandboxed `git add` and `git commit`
  work there (verified 2026-11-15 in the launch repo). The hook allows it only
  for a worktree at `<repo>/.claude/worktrees/<name>` of that same repo.
- While inside, a guard refuses compound Bash commands (`source`, heredocs,
  some pipes) and any command whose cwd is the shared checkout. Run a script
  from the scratchpad with `bash <script>`, or split the command.
- Leave with `ExitWorktree(action="keep")`. Never `remove`: post-merge cleanup
  stays the raw git commands in Protocol 6.

## Repository layout detail (claude-config)

- **Deploy clone** at `~/.local/share/claude-config` is kept on `origin/main`
  by a LaunchAgent (`com.smartwatermelon.claude-config-deploy`, every 10
  minutes; a crontab entry on a host with no GUI login).
- **Deploy now:** `claude-config-deploy`, in a terminal (outside Claude Code).
  The old `~/Developer/claude-config/install.sh --sync` now just runs that
  deploy (only `--dev` links the working checkout).
- **Dev mode:** `~/Developer/claude-config/install.sh --dev` links `~/.claude`
  to the working checkout. The status line shows `[DEV hooks]` and
  SessionStart says so. The LaunchAgent leaves it for 12 hours, then redeploys
  main. `claude-config-deploy` ends it at once.
- **Deploy health:** a refused deploy shows `[DEPLOY: <key>]` in red in the
  status line; no good run in 2 hours shows `[DEPLOY stale <age>]`.
  SessionStart prints the same notice. Next step: `claude-config-deploy status`
  in a terminal.
- This repo tracks no submodules. Plugin marketplaces under
  `~/.claude/plugins/marketplaces/` are cloned and kept current by Claude Code
  itself — runtime state, not repo content. Do not re-add one to track a
  marketplace.
- `docs/plans/` exists for design/planning docs and should be committed.
- Key scripts: `install.sh` (symlink bootstrap),
  `scripts/claude-config-deploy.sh` (deploy job, bootstrap, LaunchAgent),
  `scripts/update-tools.sh` (symlink repair + `~/.claude` audit),
  `scripts/post-push-status.sh <PR#>` (CI status polling).

## Return to Main Documentation

[CLAUDE.md](../CLAUDE.md)
