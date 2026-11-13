# Settings fan-out: three-way merge, groups, host-only rules

Status: approved by Andrew 2026-11-13. Follows `2026-11-09-split-user-settings.md`. Tracks the "Gaps found 2026-11-13" items in smartwatermelon/claude-config#862.

## Goal

A rule approved with "Yes, don't ask again" on one personal Mac reaches the other personal Macs through one fold PR, unless the rule is risky. Work machines never receive a rule automatically. No host freezes another.

## Decisions (Andrew, 2026-11-13)

- Approved rules fan out to a **group**, not to every Mac. The first group is `personal`. Work machines are in no group; a rule reaches one only when added to that machine's host file by hand in review.
- Do not name a specific work machine in new code, docs or PR text. Say "work machines". Group membership is opt-in, so a work machine is simply absent from the list.
- A **risk list** in the repo keeps a rule on the Mac that approved it (the host file). Everything else goes to the group file.
- The fold PR body lists each rule under "Personal Macs" or "This Mac only", so it reads as a grant.
- The three-way merge ships first, as its own PR, because fan-out without it makes cross-host freezes routine.

## PR 1: three-way merge (fixes gap 4)

Prior art: git's three-way merge. Base = `<out>.built` (the last build written), ours = the live file, theirs = the new build.

### Build (`scripts/build-machine-settings.sh`)

New case in `_classify`, checked before `drift`: **resolved**. Live differs from both `.built` and the new build, but every local change (live relative to `.built`) is already in the new build. Then write the new build, record `.built`, exit 0, and log one line that drift was resolved.

"Every local change is in the new build" means, for the local delta D of live against `.built`:

- an added or changed scalar at a path: the new build has the same value at that path;
- an added array item: the new build's array at that path contains it (order does not matter);
- a removed key or array item: the new build also lacks it.

Arrays of permission rules are sets in Claude Code; order-insensitive containment is correct there. Apply the same rule to every array for simplicity, and say so in `--help`.

Applies to machine-settings and user-settings alike (same script).

### Harvest (`scripts/harvest-user-settings.sh`)

1. The overlay becomes the local delta D = live against `.built` (`--built <file>`, default `<live>.built`), not live against base. Removals in D stay not harvestable (exit 3), as today.
2. Apply D to the host file from `origin/main` in the scratch clone (step 4 today), not to `--src`. The step-2 check becomes: build of (origin/main sources with D applied) contains D, by the same containment rule as the build. Exact equality with live is no longer required, because main may hold other hosts' changes.
3. The secret checks run on D only, unchanged.

### Tests (stubbed, bats)

- Gap 4 reproduction first (red): base on main gains an allow item while live lacks it and has a new rule; today this refuses. After: harvest exits 0 and the fold holds only the new rule.
- Build: live with a local edit that the new build already holds → resolved, new build written, exit 0.
- Build: local edit not in the new build → drift, exit 2 (unchanged).
- Build: a local removal the new build also lacks → resolved.

### Proof

TILSIT under cron, as before: add an exact rule with `jq`, see the fold PR, close it unmerged, restore from `.built`.

## PR 2: groups, risk list, fan-out

### Layout

- `user-settings/groups.json`: `{"personal": ["ASIAGO", "MIMOLETTE", "TILSIT"]}`. A host in no group gets no group layer.
- `user-settings/groups/<group>.json`: settings for that group.
- `user-settings/host-only-rules.txt`: one ERE per line, `#` comments. A `permissions.allow` rule matching any line stays in the host file.

### Build

Merge order: base, then each group the host is in (in `groups.json` order), then host, then local. A host in no group builds as today.

### Harvest

After both secret checks pass, split D's `permissions.allow` additions: rules matching the risk list go to `hosts/<HOST>.json`; the rest go to `groups/<group>.json` for the host's group (exactly one group required; zero or several → host file, logged). Every other key stays in the host file. Re-run the containment check with the split files; on a mismatch fall back to the host file for all rules and say so in the PR body.

Stage every changed file. The "already has this" check and the PR-body diff cover all of them. Keep each file's key order (no `jq -S` on write).

### Risk list (first version)

Commands that delete, move, overwrite or change system state; credential and secret tools; network and remote shells; deploys; and any rule broader than one tool. At least: `rm`, `mv`, `cp`, `dd`, `chmod`, `chown`, `ln`, `find .* -delete`, `git (push|reset|clean|checkout|rebase|branch -D)`, `gh (pr merge|repo delete|api)`, `op`, `security`, credential paths (`~/.ssh`, `~/.config/gh-app-keys`), `ssh`, `scp`, `rsync`, `curl`, `wget`, `launchctl`, `tmutil`, `diskutil`, `defaults write`, `sudo`, `kill`, `pkill`, `npm publish`, `wrangler deploy`, `netlify deploy`, `eas`, bare `Bash` or `Bash(*)`. Reviewed in the PR.

### PR body

Two lists: "Personal Macs (groups/personal.json)" and "This Mac only (hosts/<HOST>.json)", each rule on its own line, then the diff.

### Tests

- A low-risk rule from TILSIT lands in `groups/personal.json`; the host file is unchanged.
- A risk-list rule lands in `hosts/<HOST>.json`.
- A host in no group: every rule lands in the host file.
- Build: base + group + host order; a host in no group gets no group layer.
- PR body lists each rule under the right heading.

### Proof

TILSIT: approve a low-risk rule; the fold PR changes `groups/personal.json`. Merge it this time, then confirm MIMOLETTE's next deploy writes the rule and ASIAGO's does too, and that the work machine's build does not contain it (read only).

## Out of scope here

Gap 2 (the work machine stuck in drift) and gap 3 (a refused harvest freezes its host) stay open in #862. PR 1 reduces gap 3's reach; it does not close it.
