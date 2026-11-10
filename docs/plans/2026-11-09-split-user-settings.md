# Split settings.json into policy and preferences — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `~/.claude/settings.json` becomes a real, generated file that local writes (`/model`, `/config`, `/permissions`, iTerm2) can change without ever dirtying the deploy clone, while policy keys move to the `--settings` layer that agents cannot write.

**Architecture:** Reuse `scripts/build-machine-settings.sh` (base + host merge, placeholders, `.built` record, drift report) for a second output. Policy keys move from tracked `settings.json` into `machine-settings/base.json`. Preference keys move into a new `user-settings/` source that the same script builds into `~/.claude/settings.json`. `install.sh` stops linking `settings.json`.

**Tech Stack:** Bash 5, jq, bats (`tests/`), plain test scripts (`scripts/tests/`).

**Spec:** smartwatermelon/claude-config#842 (body, and the "Revised design" comment of 2026-11-09).

## Global Constraints

- Policy keys (to `machine-settings/base.json`): `hooks`, `env`, `deniedMcpServers`, `permissions.deny`, `permissions.ask`, `permissions.defaultMode`.
- Preference keys (stay user-scope): every other key, including `permissions.allow`, `enabledPlugins`, `extraKnownMarketplaces` and `statusLine`. Rule: a key that Claude Code itself writes at user scope (`/permissions` → `permissions.allow`, `/plugin` → `enabledPlugins`, `/statusline` → `statusLine`) must be a preference. If it were policy, the fold PR would move it to machine settings, the local file would keep it, and the drift could never clear.
- Why the `permissions` split is safe (permissions docs): "Rules are evaluated in order: deny, then ask, then allow. The first match in that order determines the outcome." A user `allow` cannot override a policy `deny`. The docs do not state the cross-scope `ask` vs `allow` case; Task 2 Step 9 verifies it.
- A user-scope write to a policy key (for example a `/hooks` edit) is drift that a fold PR cannot clear by itself. The drift report says so, and the fix is a one-time removal from the local file after the fold PR deploys.
- `autoMode` moves from `machine-settings/` to `user-settings/` with the same split: the shared part in `base.json`, the per-host part in `hosts/<HOST>.json`. The docs scope it to "User or managed", so `--settings` may ignore it today (dev-env#236).
- The `autoMode` leak guard (`tests/test_settings_no_automode.bats`, claude-config#759) exists because `/auto-mode-setup` wrote into the symlinked, shared `settings.json`. It stays until Task 3 removes that file, then retires with that reason in the commit message.
- A user-settings drift never fails the deploy. A machine-settings drift still does (unchanged).
- Builds run from the deploy clone only, never a `--dev` checkout (same guard as section 7c of `install.sh`).
- Shell: `shellcheck -S info` clean, no disable directives; `mv`/`rm` stay injected (`MACHINE_SETTINGS_MV_BIN`, `MACHINE_SETTINGS_RM_BIN`); tests write only under their own temp dir.
- Each PR: commit-time reviewers clean, CI green, Andrew approves in GitHub. Commit trailer `Advances #842`; only the last PR says `Closes #842`.

## Review Focus

1. **A host with no host file (arich-mac).** Today the build does nothing there. After Task 2, that host would get no hooks at all. Expected: Task 2 does not ship until every host that runs the deploy has a `machine-settings/hosts/<HOST>.json`. Task 2 Step 1 checks this.
2. **First run over the symlink.** `~/.claude/settings.json` is a symlink into the clone. Expected: the build replaces the link with a regular file and never writes through it into the clone. Test in Task 3.
3. **Local edits made between deploys.** Expected: kept, reported in the drift report, and the rest of the deploy proceeds. Test in Task 1.
4. **Sessions started without claude-wrapper** (`claude-incognito`, plain `claude`, `claude -p` from hooks) get no `--settings`. Expected: each caller is listed with a decision. Task 2 Step 2.
5. **iTerm2 rewriting the generated file.** Expected: it shows up as drift, never as a deploy failure. Covered by the Task 1 drift test.
6. **Hook config edits in a `--dev` checkout stop taking effect.** Machine settings build from the deploy clone only, so a `hooks` change in a dev checkout applies only after it merges and deploys. Hook-script edits still apply through the dev symlinks. Write this in the README in Task 3.
7. **New regular files inside `~/.claude/`** (`settings.json.built`, `settings.json.bak-*-pre-build`). Expected: `scripts/update-tools.sh`'s `~/.claude` audit and the prune-stale-links step leave them alone. Task 3 Step 1 adds a test.

---

### Task 1: Build script — second output with optional host file and soft drift (PR 1)

**Files:**

- Modify: `scripts/build-machine-settings.sh`
- Test: `tests/test_build_machine_settings.bats`
- Add this plan: `docs/plans/2026-11-09-split-user-settings.md`

**Interfaces:**

- Produces: `build-machine-settings.sh --src <dir> --out <file> [--report <file>] [--host-optional] [--dry-run]`.
  - `--report <file>`: drift report path (overrides `MACHINE_SETTINGS_DRIFT_REPORT`).
  - `--host-optional`: with no `<src>/hosts/<HOST>.json`, build from `base.json` alone (today: do nothing, exit 0).
  - Exit codes unchanged: 0 built/unchanged, 1 failed, 2 drift, 64 usage.

- [ ] **Step 1: Write the failing tests** in `tests/test_build_machine_settings.bats`:
  - `@test "--host-optional builds base.json alone when the host file is missing"`: output equals `jq -S` of base.json; exit 0.
  - `@test "without --host-optional a missing host file still writes nothing"`: no output file; exit 0.
  - `@test "--report writes the drift report to the given path"`: edit the output after a build, rebuild with `--report "$BATS_TEST_TMPDIR/r.diff"`; exit 2; that file exists; the default report path does not.
  - `@test "a symlinked output is replaced by a regular file, and the link target is untouched"`: output is a symlink to `$BATS_TEST_TMPDIR/target.json` holding `{"a":1}`; build (no `.built` yet); output is a regular file (`[ ! -L ]`); target still holds `{"a":1}`; a backup `<out>.bak-*-pre-build` exists.
  - `@test "a dangling symlink output is replaced by a regular file"`: in the Task 3 deploy, `git mv settings.json` removes the link's target before the build runs. Output is a link to a missing file; build exits 0; output is a regular file.
- [ ] **Step 2: Run** `bats tests/test_build_machine_settings.bats`. Expected: the five new tests fail; all others pass.
- [ ] **Step 3: Implement** the two options. The symlink case must hold by construction (temp file beside the output, then `mv` replaces the link). If `mv` over a link writes through on macOS, `rm` the link first through `RM_BIN`.
- [ ] **Step 4: Run** the same bats file. Expected: all pass. `shellcheck -S info scripts/build-machine-settings.sh` clean.
- [ ] **Step 5: Commit** both files and this plan. Open PR 1.

### Task 2: Move policy keys to machine-settings; create user-settings (PR 2)

**Files:**

- Modify: `settings.json` and `machine-settings/base.json` together, in one commit: the policy keys (Global Constraints) move out of `settings.json` into `machine-settings/base.json`, with values unchanged. Never both at once: hooks merge across scopes, so a key in both files runs every hook twice.
- Create: `tests/test_settings_split.bats`
- `settings.json` stays symlinked and now holds preferences only. `autoMode` stays in `machine-settings/` (Task 3 moves it).

**Interfaces:**

- Produces: `settings.json` with no policy keys; `machine-settings/base.json` with all of them.

- [ ] **Step 1: Check every deploy host has a machine-settings host file.** Hosts with a deploy clone: ASIAGO, TILSIT, MIMOLETTE, and maybe arich-mac. Over SSH (bare `ssh host cmd`, no pipe): `test -d ~/.local/share/claude-config && hostname -s`. If arich-mac has a clone and no `machine-settings/hosts/ARICH-MAC.json`: stop and ask Andrew whether to add one or build machine settings there with `--host-optional`.
- [ ] **Step 2: List every launch that bypasses claude-wrapper.** Today hooks apply to every launch; after this task only wrapper launches get them.
  1. Code callers: `grep -rn` for `claude -p`, `CLAUDE_BIN`, `claude-incognito` in `hooks/`, `scripts/`, and the claude-wrapper and dotfiles repos.
  2. On each Mac (bare `ssh host which claude`, no pipe): `claude` resolves to the wrapper.
  3. Other launchers Andrew uses: the desktop app, IDE extensions, iTerm2's integration. For each, find whether it goes through the wrapper.
  For each, write one line in the PR body: what it loses (hooks, deny and ask rules) and whether that is acceptable. If any answer is unknown, or a launch needs the policy hooks: stop and ask Andrew.
- [ ] **Step 2b: Check no Mac has machine-settings drift now.** On each Mac: `ssh host test ! -e .local/state/claude-config/machine-settings.drift.diff`. With drift, the PR 2 deploy would strip hooks from `settings.json` and then refuse to rebuild machine settings, leaving that Mac with no hooks. Any drift: stop and fix it first.
- [ ] **Step 3: Write `tests/test_settings_split.bats`:**
  - Variable `PREFS` = `${SETTINGS_PREFS_FILE:-settings.json}` (Task 3 sets the default to `user-settings/base.json`), so the test checks a known-bad copy too.
  - Policy paths, as jq paths: `["hooks"]`, `["env"]`, `["deniedMcpServers"]`, `["permissions","deny"]`, `["permissions","ask"]`, `["permissions","defaultMode"]`.
  - `@test "policy paths are only in machine-settings"`: each path exists in `machine-settings/base.json` (`getpath` not null) and is null in `PREFS`.
  - `@test "permissions.allow is never in machine-settings"`: null in `machine-settings/base.json` and every `machine-settings/hosts/*.json`.
  - `@test "no other key is in both files"`: top-level keys of `PREFS` and `machine-settings/base.json` intersect only in `permissions`.
- [ ] **Step 4: Run** `bats tests/test_settings_split.bats tests/test_settings_no_automode.bats`. Expected: the split tests fail; the leak guard still passes.
- [ ] **Step 5: Move the keys** with `jq` (no hand-copying of values). `permissions` exists in both files: concatenate the `deny` and `ask` lists and keep `defaultMode`. Check per host: `jq -S` of (new `settings.json` + new built machine settings) equals `jq -S` of (old `settings.json` + old built machine settings), using `build-machine-settings.sh --dry-run` with `MACHINE_SETTINGS_HOST`. Put the command and its empty diff in the PR body.
- [ ] **Step 6: Run** both bats files and `bats tests/test_build_machine_settings.bats`. Expected: all pass.
- [ ] **Step 7: Commit.** Open PR 2. Before merge: Andrew reads the launch list from Step 2, and Step 2b is rerun.
- [ ] **Step 8: After merge, verify on each Mac** (bare SSH, no pipes): `jq -e '.hooks | length > 0' .config/claude-code/machine-settings.json` and `jq -e 'has("hooks") | not' .local/share/claude-config/settings.json`. Any failure: report it at once.
- [ ] **Step 9: Verify the cross-scope `ask` rule.** The `ask` rule `Bash(git push --force *)` now comes from `--settings`. In a scratch git repo under the session scratchpad, write `.claude/settings.local.json` with `{"permissions":{"allow":["Bash(git push --force *)"]}}` (a lower scope than `--settings`). Start a wrapper session there and ask it to run `git push --force --dry-run`. Expected: Claude Code prompts. Report the result; if it does not prompt, stop and ask Andrew.

### Task 3: Switch install.sh from the symlink to the generated file (PR 3)

**Files:**

- Modify: `install.sh` (section 7c: second build call; link exclusions: add `user-settings/*`, add `settings.json`; canary at line 183: `user-settings/base.json`; remove section 8, the iTerm2 git filter, whose only file is now untracked)
- Move: `git mv settings.json user-settings/base.json`
- Move `autoMode`: the shared part from `machine-settings/base.json` to `user-settings/base.json`; each host's part from `machine-settings/hosts/<HOST>.json` to a new `user-settings/hosts/<HOST>.json` (ASIAGO, TILSIT, MIMOLETTE).
- Delete: `scripts/normalize-iterm-home.sh`, `tests/test_normalize_iterm_home.bats`, `tests/test_settings_no_automode.bats`, `.gitattributes` line `settings.json filter=iterm-home`
- Modify: `tests/test_settings_split.bats` (`PREFS` default to `user-settings/base.json`; add `@test "autoMode is only in user-settings"`: absent from `machine-settings/base.json` and `machine-settings/hosts/*.json`)
- Modify: tests that name `settings.json` (`tests/test_install_*.bats`, `tests/test_install_deploy_clone.bats`): update fixtures
- Modify: `README.md` "Shared vs machine settings"

**Interfaces:**

- Consumes: Task 1 CLI; Task 2 `user-settings/`.
- Produces: install.sh section 7c runs
  `build-machine-settings.sh --src user-settings --out "${HOME}/.claude/settings.json" --report "${HOME}/.local/state/claude-config/user-settings.drift.diff" --host-optional`.
  Exit 2 → `_warn "Local changes in ~/.claude/settings.json kept; fold preference keys into user-settings/ and policy keys into machine-settings/ via a PR. Report: <path>"`, not added to `failures[]`. Exit 1 → failure, as for machine settings.

- [ ] **Step 1: Write failing tests** (in the install test file that covers section 7c, or a new `tests/test_install_user_settings.bats`):
  - `@test "deploy clone --sync replaces the settings.json symlink with a generated file"`
  - `@test "a local edit to ~/.claude/settings.json is kept and the sync still succeeds"` (exit 0, warning names the report)
  - `@test "--dev does not build user settings"`
  - `@test "settings.json is no longer linked into ~/.claude"`
  - `@test "the ~/.claude audit and prune leave settings.json.built and .bak-*-pre-build alone"`
- [ ] **Step 2: Run** them. Expected: fail.
- [ ] **Step 3: Implement** the install.sh changes listed under Files. Remove section 8 only after confirming nothing else names `filter.iterm-home` (`grep -rn iterm-home`).
- [ ] **Step 4: Run** the scoped tests: every `tests/test_install_*.bats`, `tests/test_build_machine_settings.bats`, `tests/test_settings_*.bats`, `scripts/tests/test-claude-config-deploy.sh`. Expected: all pass. Full suite runs in CI only.
- [ ] **Step 5: Commit** with `Advances #842`. Open PR 3.
- [ ] **Step 6: After merge, verify on each Mac** (bare SSH, no pipes): `test -f ~/.claude/settings.json && ! test -L ~/.claude/settings.json`; the deploy log shows the build; `git -C ~/.local/share/claude-config status --porcelain` is empty. Report per host.

### Task 4: Harvest user-settings drift into a PR automatically (PR 4)

Approved by Andrew 2026-11-09: local changes to `~/.claude/settings.json` become a PR without anyone asking.

**Files:**

- Create: `scripts/harvest-user-settings.sh`
- Modify: `scripts/claude-config-deploy.sh` (after a successful install, if `${STATE_DIR}/user-settings.drift.diff` exists, run the harvest; a harvest failure is logged and notified, never fails the deploy)
- Modify: `install.sh` link exclusions only if the new script must not link into `~/.claude` (follow how `build-machine-settings.sh` is handled)
- Test: `tests/test_harvest_user_settings.bats`

**Interfaces:**

- Consumes: Task 1's `build-machine-settings.sh --src --out --host-optional --dry-run` and `MACHINE_SETTINGS_HOST`; Task 3's `user-settings/` layout and drift report path.
- Produces: `harvest-user-settings.sh --live <file> --src <user-settings dir> --host <HOST> --repo <owner/name> [--dry-run]`. Exit 0: PR opened or updated, or nothing to do. Exit 3: not harvestable (overlay mismatch, secret found, scanner missing); notified, no push. Exit 1: failed.
- Injected binaries for tests: `HARVEST_GIT_BIN`, `HARVEST_GH_BIN`, `HARVEST_GITLEAKS_BIN`, `HARVEST_NOTIFY_BIN`.

Algorithm (the parts the tests do not fix):

1. Overlay = the parts of `jq -S` live that differ from `jq -S` `<src>/base.json`. Objects: recurse. Arrays: the overlay holds live items not in the base array (the build appends host arrays). A key that is in base but missing or changed in a way an overlay cannot express shows up in step 2.
2. Write the overlay as `hosts/<HOST>.json` in a temp copy of `<src>`, build with `--dry-run`, and compare with live (`jq -S` equality). Mismatch → exit 3, with the diff in the notification log.
3. Check the overlay for secrets in two ways. A failure in either → exit 3: notified, no push. Never put the scanned content in the log or notification; name only the JSON path and the check that failed.
   1. **Shape check (primary).** Gitleaks alone is not enough. On 2026-11-10, gitleaks 8.30.1 caught 2 of 8 fake secrets in `permissions.allow` rules (a `ghp_` PAT, an `sk-ant-` key). It missed `Authorization: Bearer <token>`, `sk-proj-…`, `mysql -p<password>`, `https://user:<pass>@host`, `postgresql://app:<pass>@host` and `netlify deploy --auth <token>`. "Yes, and don't ask again" saves the whole command text as a rule (Apiiro, 2026-11-05), so a secret typed into a command becomes a rule. Reject the overlay if:
      - any new or changed `env` value exists (env is where credentials live; Andrew moves those by hand);
      - any `permissions.allow`, `permissions.ask` or `permissions.deny` entry is neither a bare tool name (`WebFetch`) nor a prefix rule (`Tool(<prefix>:*)` or `Tool(<prefix> *)`), because an exact-command rule is the shape "don't ask again" writes;
      - any string in the overlay holds a run of 20 or more characters from `[A-Za-z0-9+/=_-]` that is not a path segment, or `://<user>:<pass>@`, `Bearer`, `Authorization:`, `-p<non-space>`, `--auth`, `--token`, `--password`, `--secret`, or `<NAME>=<value>` where `<NAME>` contains `TOKEN`, `SECRET`, `PASSWORD`, `PASSWD`, `CREDENTIAL` or the word `KEY` (the name list in `scripts/hook-block-secret-leak.py`).
   2. **Gitleaks (second check).** Scan the overlay file with gitleaks (`gitleaks dir <file>` or the installed version's equivalent; check `gitleaks --help`). A finding, or no gitleaks binary → exit 3.
4. Scratch clone at `~/.local/state/claude-config/harvest/` (never the deploy clone, never a worktree of it). Branch `claude/harvest-settings-<host-lower>` from `origin/main`. Commit `chore(settings): fold <HOST> local settings`. Push with `--force-with-lease`; hooks off as in the deploy (`NO_HOOKS`), because the content is data and was scanned.
5. `gh pr list --head <branch>`: none open → `gh pr create` (body: the overlay diff and "Fold into base.json in review if it applies to every Mac"); one open → the push updated it.

- [ ] **Step 1: Write the failing tests** in `tests/test_harvest_user_settings.bats` (stub git, gh, gitleaks, notify; all paths under `BATS_TEST_TMPDIR`):
  - `@test "an added permissions.allow rule becomes a host overlay holding only that rule"`
  - `@test "a changed scalar (model) becomes a host overlay with the new value"`
  - `@test "a base key removed locally is not harvestable: exit 3, notified, no push"`
  - `@test "a gitleaks finding stops the harvest: exit 3, no push, the secret is not in the log"`
  - `@test "no gitleaks binary: exit 3, no push"`
  - `@test "the shape check stops each secret gitleaks missed: exit 3, no push, the secret is not in the log"` (one case per missed shape in step 3.1, values generated at test time, gitleaks stubbed to report nothing)
  - `@test "a new env value stops the harvest: exit 3, no push"`
  - `@test "an exact-command allow rule stops the harvest; a prefix rule passes"`
  - `@test "an open harvest PR is updated by push, not duplicated"` (`gh pr create` not called)
  - `@test "no open PR: gh pr create is called once with the branch"`
  - `@test "--dry-run pushes nothing and creates no PR"`
  - In `scripts/tests/test-claude-config-deploy.sh`: a drift report present → harvest runs once; a harvest exit 1 or 3 → deploy exit 0, harvest outcome logged.
- [ ] **Step 2: Run** the bats file and the deploy test script. Expected: the new tests fail.
- [ ] **Step 3: Implement** `harvest-user-settings.sh` and the deploy hook.
- [ ] **Step 4: Run** both test files and `shellcheck -S info` on every changed script. Expected: all pass, clean.
- [ ] **Step 5: Commit** with `Closes #842`. Open PR 4.
- [ ] **Step 6 (controller, after merge):** check that gitleaks is installed on each Mac (bare `ssh host command -v gitleaks`). Then on ASIAGO, approve one harmless rule in `/permissions` at user scope and wait one deploy cycle (10 minutes). Expected: one PR titled `chore(settings): fold ASIAGO local settings`, opened by the agent App. Close it without merging if the rule is not wanted.
