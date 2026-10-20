# Plan: per-machine settings without the full claude-wrapper

**Status:** done — claude-wrapper#143, dotfiles#448, claude-config#759 merged 2026-10-20
**Date:** 2026-10-20
**Author:** arich (drafted by Claude Code)

## Problem

`~/.claude/settings.json` is a symlink into this repo, so every key in it ships
to every machine. Machine-specific settings keep landing there anyway:
`/auto-mode-setup` and the `/permissions` Auto mode tab write `autoMode` into
`~/.claude/settings.json` by design, and `claude auto-mode reset` removes it
from that same file. On
2026-10-20 a Beacon-only `autoMode.environment` block (25 entries describing
`andrewmrich/beacon-workspace`) appeared as an uncommitted diff here.

Claude Code has no user-level settings file outside `~/.claude/settings.json`:

- `~/.claude/settings.local.json` is local (project) scope. It loads only in
  sessions started in `~` itself.
- The classifier ignores `autoMode` in any project `.claude/settings*.json`.
- It reads `autoMode` only from `~/.claude/settings.json`, managed settings, and
  `--settings` (<https://code.claude.com/docs/en/auto-mode-config>).

`smartwatermelon/claude-wrapper` already solves this (`lib/machine-settings.sh`,
claude-wrapper#138): it passes `~/.config/claude-code/machine-settings.json`
with `--settings`. But the full wrapper is deliberately not installed on the
Beacon machine — it carries 1Password, identity, and remote-session machinery
for personal/NOS work that Beacon does not need.

## Measured `--settings` merge behavior

Claude Code 2.1.305, 2026-10-20. claude-wrapper's README notes most of this as
unmeasured.

| Case | Result |
| --- | --- |
| Same 25-entry `autoMode.environment` in `settings.json` and `--settings` | 50 entries: arrays concatenate |
| `--settings '{"env":{"OVERLAY_PROBE":"yes"}}'` | `BASH_DEFAULT_TIMEOUT_MS` from `settings.json` still set: objects merge by key |
| `--settings a.json --settings b.json` | only `b.json` applied: the flag does not stack, last one wins |

Consequences: an overlay can add array entries but never remove them, can
override single object keys, and must be one file.

## Design

One implementation: claude-wrapper's `lib/machine-settings.sh`. Its
dependencies (`logging.sh`, `permissions.sh`, `remote-session.sh`) have no
side effects when sourced, so they can run without the rest of the wrapper.

1. **claude-wrapper:** `bin/claude-wrapper-lite` sources those four libs, adds
   `build_machine_settings_args`, and execs `caffeinate -is` + the claude
   binary. No secrets, identity, or remote control.
2. **Beacon machine:** clone claude-wrapper; link only `claude-wrapper-lite`
   onto PATH.
3. **dotfiles:** `bash/aliases.sh` uses `claude-wrapper` if present, else
   `claude-wrapper-lite`, else plain `caffeinate -i claude`.
4. **claude-config (this repo):**
   - README section: shared vs machine settings, and the merge table above.
   - Leak guard: a bats test failing if `settings.json` has a top-level
     `autoMode`, pointing at `machine-settings.json`.
   - Note: `/auto-mode-setup` writes `environment` without `"$defaults"`, so
     that list stops inheriting new built-in entries.

## Out of scope / follow-ups

- Splitting claude-wrapper fully into base + beacon + personal layers.
- Desktop and IDE launches bypass shell launchers. Only managed settings or a
  generated `settings.json` would reach them.
