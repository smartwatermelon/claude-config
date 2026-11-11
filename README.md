# Claude Code Configuration

Personal Claude Code configuration for Andrew Rich.

## Setup

**Do NOT clone this repo directly into `~/.claude`.** Two checkouts exist on
each machine (#453):

- `~/Developer/claude-config`: the working checkout. Edit, branch, pull.
- `~/.local/share/claude-config`: the deploy clone, always on `origin/main`.
  `~/.claude` links into it. It sits outside the Claude Code sandbox's
  writable paths, so no session can change the hooks that run. A branch
  switch in the working checkout cannot reach them either.

```bash
# 1. Clone the working checkout
git clone git@github.com:smartwatermelon/claude-config.git ~/Developer/claude-config

# 2. Bootstrap (run in a terminal, not in Claude Code): clones the deploy
#    clone over anonymous HTTPS, runs its install.sh --sync, and loads the
#    LaunchAgent. Idempotent; safe to re-run.
~/Developer/claude-config/scripts/claude-config-deploy.sh bootstrap
```

Runtime state (sessions, projects, telemetry, etc.) stays in `~/.claude`
untouched.

### How it works

`install.sh` discovers tracked files via `git ls-files` and creates per-file
symlinks from the checkout it lives in into `~/.claude`. Repo-meta files
(`.github/`, tests, README, etc.) are excluded.

```
~/.local/share/claude-config/hooks/run-review.sh  -->  ~/.claude/hooks/run-review.sh  (symlink)
~/.local/share/claude-config/user-settings/  ==>  ~/.claude/settings.json  (built, a regular file)
```

`settings.json` is the exception: it is built, not linked (see
[Shared vs machine settings](#shared-vs-machine-settings)).

### Deploying

The LaunchAgent `com.smartwatermelon.claude-config-deploy` runs
`claude-config-deploy.sh deploy --scheduled` every 10 minutes. On a host
where the user has no GUI login, a crontab entry runs it instead. It fetches
origin; when `main` moved it fast-forwards the clone and runs the clone's
`install.sh --sync`. It refuses, logs and notifies (and changes nothing) when
the clone has local changes, is off `main`, or cannot fast-forward.

| Command | Effect |
|---------|--------|
| `claude-config-deploy` | Deploy `origin/main` now; also ends dev mode |
| `claude-config-deploy status` | Clone commit, link mode, agent state, last log lines |
| `claude-config-deploy uninstall` | Remove the LaunchAgent, the cron entry and the command link; keeps the clone |
| `~/Developer/claude-config/install.sh --dev` | Dev mode: link `~/.claude` to the working checkout |

Log: `~/.local/state/claude-config/deploy.log`. Exit codes: 0 ok, 1 failed,
2 refused, 3 another run holds the lock, 64 usage.

**Dev mode** is for testing a hook change before it merges. The status line
shows `[DEV hooks]`, SessionStart prints a notice, and each scheduled run logs
it. The LaunchAgent leaves dev mode alone for 12 hours
(`CLAUDE_CONFIG_DEV_TTL_HOURS`), then redeploys `main`, so a machine is not
left in it by accident. `claude-config-deploy` ends it at once.

Once the deploy clone exists, the working checkout's script hands every run
except `--dev` to the clone. A `--sync` or full install runs
`claude-config-deploy`. A `--repair` or `--dry-run` runs the clone's copy of
the script. So old instructions, and the dotfiles `allup` and `dotclaude`
functions, deploy `main` instead of relinking the working tree.

### install.sh flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Show what would be done without making changes |
| `--repair` | Fix broken symlinks (atomic write recovery) |
| `--sync` | Repair, then link newly added files |
| `--dev` | Working checkout only: link `~/.claude` to it until the next deploy |
| `--help` | Show usage |

The script is idempotent — safe to run repeatedly.

Every mode also prunes stale links. A link in `~/.claude` that points into
this repo at a missing file is removed, and so is any directory that leaves
empty. `--sync` from one checkout also removes links
into the other checkout for files it does not track (dev-mode leftovers).
Links pointing anywhere else are never touched.

### Ongoing maintenance: update-tools.sh

`scripts/update-tools.sh` is called automatically by the `updates` shell
command (via `_claude_update()`). It:

1. **Repairs** broken symlinks via the deploy clone's `install.sh --repair`
   (skipped in dev mode)
2. **Audits** `~/.claude`: categorizes entries as symlinked (repo-managed),
   known-runtime (Claude Code managed), or unknown (needs human triage).
   `--learn` writes new entries to the working checkout's
   `scripts/known-runtime.txt`, for a commit.

### Submodules

None. This repo tracks no submodules.

Marketplaces are cloned and updated by Claude Code itself under
`~/.claude/plugins/marketplaces/`, registered in
`~/.claude/plugins/known_marketplaces.json`. They are runtime state, not repo
content, so there is no pointer here to bump.

## Installed Plugins

Plugins are sourced from marketplaces registered in
`~/.claude/plugins/known_marketplaces.json` and managed by Claude Code.
Enabled state is tracked in `user-settings/base.json`, which the deploy
builds into `~/.claude/settings.json`.

### From smartwatermelon-marketplace

- **code-critic** ✓ — adversarial code review agent
- **comprehensive-review** ✓: vendored from wshobson/agents, with 3 agents (code-reviewer, architect-review, security-auditor). Its code-reviewer is the default commit-time reviewer; see `plugins/comprehensive-review/README.md` in that repo for provenance
- **superpowers** ✓ — hook-less vendored subset of obra/superpowers (brainstorming, planning, subagent-driven development, debugging, TDD, code review, verification). Vendored so upstream's SessionStart hook no longer injects `using-superpowers` into every session; see `plugins/superpowers/README.md` in that repo
- **react-native-3d** — 3D rendering with React Three Fiber, expo-gl, Three.js (disabled on some machines — see [Per-Machine Notes](#per-machine-notes))

### From claude-plugins-official

- **frontend-design** ✓ — production-grade frontend UI generation

### From personify

- **personify** ✓ — strips AI-writing tells from prose before it's sent, published, or shipped; replaces the retired blader/humanizer submodule

### From pr-review

- **pr-review** ✓ — deep-dive review of a teammate's GitHub pull request, staged as a pending review for explicit approval before anything is posted

## Per-Machine Notes

`user-settings/base.json` is built into `~/.claude/settings.json` on every
machine, so plugin choices are global by default. Machines with a narrower purpose
disable what they don't need rather than forking the config.

Some extensions are off in `user-settings/base.json` and switched back on only where
they are used. Each one puts its skill list in context on every session
(estimated from the descriptions, 2026-11-04):

- `sentry@claude-plugins-official`: 8 skills, about 750 tokens.
- `cloudflare@cloudflare`: 19 skills, about 1,050 tokens. Not in
  `user-settings/base.json` at all; machines that use it enable it themselves.
- `morning-andrew` and `evening-andrew` (`skillOverrides`): Beacon briefs,
  about 300 tokens together.

A machine turns one back on in `~/.config/claude-code/machine-settings.json`
(see [Shared vs machine settings](#shared-vs-machine-settings)). Plugins
need `enabledPlugins`; `skillOverrides` doesn't apply to plugin skills.

```json
{
  "enabledPlugins": { "sentry@claude-plugins-official": true },
  "skillOverrides": { "morning-andrew": "on" }
}
```

`cowork-plugin-management@synced` is off everywhere: its skills need Cowork
mode and do nothing in Claude Code.

`docx`, `pptx` and `xlsx` sync from claude.ai, which has no switch for them.
`skillOverrides` sets them to `"off"` because no machine makes Office files.

| Machine | Purpose | Deviates from default by |
|---|---|---|
| MIMOLETTE | Night Owl Studio app development. | `sentry` and `cloudflare` enabled in `machine-settings.json`. |
| TILSIT | Media server (Plex). | `cloudflare@claude-plugins-official` enabled in `machine-settings.json`. |
| Beacon Biosignals work laptop (arich-mac, `arich@...`, provisioned 2026-07-12) | Infrastructure work: Python/Bash, infra CLIs, web-based tools, ssh. No app/mobile dev. | `frontend-mobile-development` and `react-native-3d` disabled, because no Android/iOS/Expo/React Native work happens on this machine. Also `morning-andrew` and `evening-andrew` set to `"on"` in `machine-settings.json`. |

When setting up a new machine: check this table first. If the new machine's
purpose matches an existing entry, replicate its deviations; if it's closer
to the personal-dev default, leave everything enabled and don't add a row
just to say so. Add a row only when a machine's plugin set actually diverges
from the tracked default.

### Shared vs machine settings

Two files, two layers. Each build merges `base.json`, `hosts/<HOST>.json`
and an optional local overlay that stays on the machine. The deploy clone's
`install.sh --sync` runs both builds with the script
`scripts/build-machine-settings.sh`.

| Built file | From | Holds | Agent-writable |
| --- | --- | --- | --- |
| `~/.config/claude-code/machine-settings.json` | `machine-settings/` | policy: `hooks`, `env`, `deniedMcpServers`, `permissions.deny`, `permissions.ask`, `permissions.defaultMode`, `sandbox` | no |
| `~/.claude/settings.json` | `user-settings/` | preferences: every other key, including `permissions.allow`, `enabledPlugins`, `statusLine` and `autoMode` | yes |

Not yet moved: `machine-settings/hosts/` still sets per-host `enabledPlugins`
(TILSIT, MIMOLETTE) and `skillOverrides` (ARICH-MAC).

`~/.claude/settings.json` is a regular file, not a symlink into this repo
(#842). Claude Code (`/model`, `/config`, `/permissions`) and iTerm2 write
it. A local change is kept. The next deploy leaves the file alone, logs a
warning, and writes a report to
`~/.local/state/claude-config/user-settings.drift.diff`. The deploy doesn't
fail. Fold a preference key into `user-settings/` with a PR, or a policy key
into `machine-settings/`. The next deploy then clears the report.

The user build's local overlay is
`~/.config/claude-code/user-settings.local.json`. It isn't
`~/.claude/settings.local.json` (see below).

`machine-settings.json` is in no repo. A launcher passes it to Claude Code
with `--settings`:

- `claude-wrapper` from
  [smartwatermelon/claude-wrapper](https://github.com/smartwatermelon/claude-wrapper)
  does this through `lib/machine-settings.sh`.
- `bin/claude-wrapper-lite` in the same repo (claude-wrapper#143) uses the
  same library but loads no secrets, sets no git identity, and starts no
  remote control. Link it as `~/.local/bin/claude-wrapper-lite`; dotfiles'
  `aliases.sh` prefers it when the full wrapper is absent. See
  `docs/plans/2026-10-20-machine-settings-launcher.md`.

`lib/machine-settings.sh` adds the file only when all of these hold:

- The session is interactive.
- No `--settings` is already on the command line.
- You own the file, and group and others can't write it.
- `jq` reads it as a JSON object.

Otherwise the session starts with the user settings only.

Both files build from the deploy clone only, never from a `--dev` checkout.
In dev mode, an edit to `machine-settings/` or `user-settings/` takes effect
only after it merges and deploys. That includes a `hooks` entry. Edits to
the hook scripts themselves still apply at once through the dev links.

Two places look right and are not:

- `~/.claude/settings.local.json` is not a user-level file. It is local
  (project) scope for `~`, so it loads only in sessions started in `~` itself.
- `autoMode` in a project `.claude/settings*.json` is ignored
  ([docs](https://code.claude.com/docs/en/auto-mode-config)). The docs list
  user and managed settings as its scopes, so it lives in `user-settings/`.
  The table below shows that `--settings` entries do merge into the
  effective `autoMode`. Whether the classifier acts on them isn't checked
  (dev-env#236).

The `/auto-mode-setup` command and the `/permissions` Auto mode tab write
`autoMode` into the user file `~/.claude/settings.json` on this Mac. To keep
the change, fold it into `user-settings/` with a PR, as for any other local
change. Also, `/auto-mode-setup` writes
`environment` without `"$defaults"`. The draft spells out the built-in
entries as they were at setup time. That list then stops inheriting new
built-in entries from later releases.

How `--settings` merges with `settings.json` (measured on Claude Code
2.1.305, 2026-10-20):

| Case | Result |
| --- | --- |
| Same 25-entry `autoMode.environment` in `settings.json` and `--settings` | 50 entries: arrays concatenate |
| `--settings '{"env":{"OVERLAY_PROBE":"yes"}}'` | `BASH_DEFAULT_TIMEOUT_MS` from `settings.json` still set: objects merge by key |
| `--settings a.json --settings b.json` | only `b.json` applied: the flag does not stack, last one wins |

So an overlay can add array entries but cannot remove them. It can override
single object keys. It must be one file.

## Architecture

### Plugin Loading

```
~/.claude/
├── plugins/
│   └── marketplaces/
│       ├── claude-plugins-official       # Plugin marketplace
│       ├── smartwatermelon-marketplace   # Personal marketplace
│       ├── personify                     # Plugin marketplace
│       └── pr-review                     # Plugin marketplace
├── settings.json                         # built from user-settings/ (enabledPlugins and other preferences)
│                                          # (notable keys documented in docs/INFRASTRUCTURE.md § Settings Rationale)
├── plugins/installed_plugins.json        # Runtime state (not tracked)
└── plugins/known_marketplaces.json       # Runtime state (not tracked)
```

### Runtime State

The following files are generated by Claude Code and are NOT tracked in git:

- `plugins/installed_plugins.json` - Contains absolute install paths
- `plugins/known_marketplaces.json` - Contains absolute marketplace locations

These files are regenerated based on the marketplace structure and the `enabledPlugins` map in `~/.claude/settings.json`.

## Git Hooks

Automated code review and safety hooks are configured in `hooks/` and `scripts/`:

- **hooks/pre-merge-review.sh** — AI review gate before merging PRs
- **hooks/run-review.sh** — per-commit AI code review runner
- **hooks/merge-lock.sh** — merge authorization lock (30-min TTL, keyed on repo + PR number)
- **scripts/hook-block-all.sh** — dispatches all PreToolUse hook-block scripts
- **scripts/hook-block-api-merge.sh** — blocks REST/GraphQL merge bypasses
- **scripts/hook-block-gh-auth.sh** — blocks `gh auth` subcommands that reach gh's keyring token
- **scripts/hook-block-no-verify.sh** — blocks `--no-verify` flag usage
- **scripts/hook-block-main-commit.sh** — blocks commits directly to main
- **scripts/hook-session-start.sh** — injects session context on startup
- **scripts/status-line.sh** — custom Claude Code status line

See `CLAUDE.md` for protocol documentation.

## Commands

`install.sh` links these into `~/.local/bin` or `~/Applications`, pointing at the deployed copy in `~/.claude`:

- **merge-lock.command** (`hooks/merge-lock.command`, in `~/Applications`) — double-click launcher that opens `merge-lock tui` in a new Terminal window
- **claude-config-deploy** (`scripts/claude-config-deploy.sh`): linked by `claude-config-deploy.sh bootstrap`, not `install.sh`. The link goes straight to the deploy clone's copy, not through `~/.claude`, so dev mode cannot redirect the deploy command.
- **claude-incognito** (`scripts/claude-incognito.sh`) — one-shot `claude -p` run that leaves no transcript, `/resume` entry, or `history.jsonl` line (print mode only). Defaults to `--permission-mode bypassPermissions` and denies only the claude.ai Slack connector so the Slack plugin and Claude Docs both load; see the script header

## Reference

- Main config: [CLAUDE.md](./CLAUDE.md)
- Superpowers: vendored in <https://github.com/smartwatermelon/smartwatermelon-marketplace> (`plugins/superpowers`, from obra/superpowers)
- comprehensive-review: vendored in <https://github.com/smartwatermelon/smartwatermelon-marketplace> (`plugins/comprehensive-review`, from wshobson/agents)
- Personify skill: <https://github.com/twistedmelonman/personify>
- pr-review skill: <https://github.com/smartwatermelon/pr-review>
