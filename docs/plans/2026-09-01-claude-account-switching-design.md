# Design: repo/org-aware Anthropic account switching for claude-wrapper

Status: DRAFT — scoped and researched 2026-09-01, not yet implemented.
Revisit before starting implementation.

## Goal

`claude-wrapper` currently launches every session under whichever Anthropic
account is logged into the machine's default `~/.claude`. The ask is to pick
the account automatically from the repo the session is launched in:

1. A repo owned by the `beacon-biosignals` GitHub org → the Beacon account.
2. A repo owned by `smartwatermelon` or Night Owl Studio
   (`nightowlstudiollc`) → the personal account.
3. Anything else (third-party org, no git repo, no remote) → the machine's
   default identity, untouched. On the personal machine that default is
   already personal; on the company machine it's already Beacon.

Condition 3 requires no new logic — it's what already happens when nothing
overrides `CLAUDE_CONFIG_DIR`/the stored login. The design only has to cover
the two explicit-override cases.

## Non-goals for v1

These are real gaps the research surfaced, but they're separable follow-ups,
not blockers for the account switch itself:

- `credentials.sh` unconditionally injects a personal-scoped `GH_TOKEN`.
  `gh` gives env-var auth precedence over `gh auth switch`'s stored identity,
  so a beacon-biosignals session today likely runs `gh` calls as the wrong
  identity regardless of this feature. Worth fixing, but independent of
  which Anthropic account is active.
- `git-identity.sh` unconditionally sets `GIT_AUTHOR_NAME/EMAIL` to the
  `smartwatermelon` bot identity, which would override dotfiles'
  `includeIf gitdir:.../beacon-biosignals/` git config for any commit made
  through this wrapper.
- Per-org 1Password vault selection (`credentials.sh`/`secrets-loader.sh`
  only know about the `Automation` vault).
- The "beacon fork living under a personal name" second-tier heuristic that
  `gh-wrapper.sh` has for `gh` identity (checkout path under
  `BEACON_WORKDIR`, or an `upstream` remote pointing at
  `beacon-biosignals`). The three stated conditions are owner-only; add the
  heuristic later only if it turns out to matter for Claude Code sessions
  the way it does for `gh`.

## Prior art already in the fleet

- `dotfiles/bash/gh-wrapper.sh` already solves repo→identity resolution for
  `gh`: `_gh_wrapper_resolve_owner` strips the owner out of
  `git config --get remote.origin.url` (handling both `git@host:` and
  `https://` remote forms), an explicit-owner table decides the identity,
  and it fails closed (refuses to proceed) if the target identity isn't
  authenticated, rather than silently running as the wrong one.
- `claude-config/hooks/lib-review-issues.sh` already branches its own
  behavior on `REPO_OWNER == "beacon-biosignals"` (private Apple Note vs.
  GitHub issue for non-blocking findings) — evidence the existing hook
  architecture already expects one shared `~/.claude` that behaves
  differently by org, not two fully separate config trees.
- `dotfiles/bash/env.sh` defines `BEACON_WORKDIR`
  (`~/Developer/beacon-biosignals` by default) as the canonical "this
  checkout is Beacon work" signal, used by both `git config`'s
  `includeIf gitdir:` block and `gh-wrapper.sh`'s fallback heuristic.

## What was verified about Claude Code's auth model

Researched against `code.claude.com/docs/en/authentication.md` and
`remote-control.md`, plus open GitHub issues, since this determines which
mechanism is even possible:

- No native multi-account switch exists (no `--account`/`--profile` flag, no
  `claude account switch`).
- `claude login` persists to macOS Keychain (falling back to
  `~/.claude/.credentials.json` when Keychain is locked, e.g. over SSH) or
  to `~/.claude/.credentials.json` directly on Linux.
- `CLAUDE_CONFIG_DIR` is the only way to get two independent stored logins
  on one machine, but it relocates *everything* under `~/.claude/` — not
  just credentials: `settings.json` (hooks), skills, plugins, agents, the
  global CLAUDE.md, and `.claude.json` (per-project trust state, MCP server
  registry). Pointing it at a bare new directory silently drops every
  Mandatory Protocol and hook this file describes.
- `claude setup-token` mints a long-lived (1 year) OAuth token for
  `CLAUDE_CODE_OAUTH_TOKEN`. It's an interactive, browser-based, one-time
  mint per account — no `--json`/`--print` machine-readable output mode
  exists yet (open feature requests: anthropics/claude-code#48373,
  anthropics/claude-code#57400). Confirmed already in production use in
  this fleet: `claude-wrapper/.github/workflows/claude.yml` and
  `claude-blocking-review.yml` pass `secrets.CLAUDE_CODE_OAUTH_TOKEN`
  straight into a reusable workflow with zero manual login step.
- Precedence rule that matters most for this design: **a stored `/login`
  credential in a given `CLAUDE_CONFIG_DIR` always wins over
  `CLAUDE_CODE_OAUTH_TOKEN`** set in that same process's environment. The
  token only takes effect in a config dir that has no stored login. This is
  exactly why the GitHub Actions case "just works" with no login step — a
  fresh runner's `~/.claude` never had a stored credential to lose to in the
  first place.
- `CLAUDE_CODE_OAUTH_TOKEN` (like an API key) cannot establish Remote
  Control sessions or fetch claude.ai connectors — those need a full-scope
  `/login` credential. It does not limit core coding functionality (Bash,
  Read/Write/Edit, locally-configured MCP servers all work) — only
  claude.ai-hosted features (Remote Control, Routines, Code Review-as-a-
  claude.ai-feature, the Chrome extension, remote connectors).
- No CLI revoke for a minted setup-token exists yet; revocation happens
  only through the claude.ai web UI and can take up to ~4 days to actually
  invalidate the token server-side (anthropics/claude-code#43801). Treat a
  minted token as long-lived and handle it with the same care as `GH_TOKEN`.

Beacon-specific fact (confirmed by Andrew, not discoverable from the repos):
**Remote Control is already blocked at the Beacon admin/account level**,
independent of which auth mechanism reaches it. That means the token's
"no Remote Control" limitation costs nothing on the Beacon side — a full
interactive `claude login` there wouldn't get Remote Control either.

## Design

The mechanism is asymmetric by direction, because "preserve Remote Control"
only matters for the personal account, and Beacon already can't have it
regardless of mechanism:

| Case | Mechanism |
|---|---|
| beacon-biosignals repo, on the company machine | No override — machine default is already the Beacon login. |
| beacon-biosignals repo, on the personal machine | `CLAUDE_CODE_OAUTH_TOKEN` (minted once, stored like `GH_TOKEN` is today) + a `CLAUDE_CONFIG_DIR` that has hooks/skills/CLAUDE.md symlinked in from this repo but **no stored credential file**, so the token isn't shadowed by the precedence rule. No interactive login needed in this directory, ever. |
| smartwatermelon/nightowlstudiollc repo, on the personal machine | No override — machine default is already personal, full Remote Control. |
| smartwatermelon/nightowlstudiollc repo, on the company machine | A real `CLAUDE_CONFIG_DIR` split with a one-time interactive `claude login` as the personal account. This is the only cell that still needs a manual login, because Remote Control must keep working here. |
| Neither (third-party org, no repo, no remote) | No override. |

Three of the four override cells resolve to "do nothing." Only one
direction (personal identity, on the company machine) still needs a real
mirrored config directory with an interactive login; the other override
(Beacon identity, on the personal machine) is materially cheaper thanks to
the token.

## Making it a severable module, not a fifth wrapper lib file

The instinct to keep this decoupled from the rest of
claude-config/claude-wrapper/dotfiles is right — it's a single, well-bounded
concern (map a repo to an account, emit env vars) and shouldn't need to pull
in `secrets-loader.sh`, `pre-launch.sh`, or any of the other wrapper
machinery to work or to be tested. Proposed shape:

- **One standalone script**, no dependency on other `claude-wrapper/lib/*`
  files beyond (at most) `logging.sh`'s debug helper. It should be usable
  on its own — sourced by `claude-wrapper`, but just as easily invoked
  directly (`eval "$(claude-account-context)"` from a bare shell function,
  or lifted into a different wrapper entirely) without dragging in
  anything else.
- **Owner resolution reimplemented locally** (the same small
  strip-the-host-prefix `sed`/parameter-expansion `gh-wrapper.sh` already
  uses), rather than sourcing `dotfiles/bash/gh-wrapper.sh` — keeps
  claude-wrapper from taking a cross-repo dependency for a ~10-line parse.
- **Data-driven mapping**, not hardcoded org names in the shell logic. A
  small config file maps owner → `{config_dir, oauth_token_1password_ref}`
  or "no override." This is what actually answers "associate repos/orgs
  with Anthropic accounts" as configuration rather than as branches buried
  in shell — adding a third org later, or changing which account owns
  which org, is an edit to the config file, not the script. Exact format
  (pipe-delimited conf, small JSON, env-var block) is an open question for
  the next pass, not decided here.
- **One entry point**: given the current directory (or an explicit repo
  path), it either prints/exports the right `CLAUDE_CONFIG_DIR` and/or
  `CLAUDE_CODE_OAUTH_TOKEN`, or emits nothing when no override applies.
  `bin/claude-wrapper` sources this module and calls that one function —
  a single integration point that's easy to unhook if the mechanism ever
  needs to change again.

## One-time setup (manual, once per machine, not part of the module itself)

- **Personal machine**: create the Beacon-side `CLAUDE_CONFIG_DIR`
  (symlink-bootstrap it from this repo the way `install.sh` already does
  for `~/.claude`, but skip credentials entirely). Mint
  `CLAUDE_CODE_OAUTH_TOKEN` once via `claude setup-token` while logged into
  the Beacon account, store it in 1Password, reference it from the mapping
  config.
- **Company machine**: create the personal-side `CLAUDE_CONFIG_DIR`
  (same symlink-bootstrap), then run an interactive `claude login` under it
  once, as the personal account.

## Open questions to resume with tomorrow

1. Exact mapping-config file format and location.
2. Which 1Password vault holds the minted Beacon token — reuse the
   existing `Automation` vault `credentials.sh` already authenticates
   against, or a separate item/vault, given this credential isn't a GitHub
   token.
3. Whether to fold the `GH_TOKEN`/git-identity gaps (see Non-goals) into
   the same change or file them as separate follow-up work — leaning
   toward separate, to keep this module minimal and actually severable.
4. Token lifecycle: 1-year expiry with no CLI list/revoke yet. Needs some
   reminder mechanism before it silently expires (a calendar reminder tied
   to the mint date is probably enough for v1; nothing programmatic exists
   to hook into).
5. Test approach: unit-test the owner-resolution parsing against fake git
   remotes (mirroring `tests/test-wrapper.sh`'s existing style); the actual
   `CLAUDE_CONFIG_DIR`/token-switch behavior can only be verified by hand
   on the two real machines.
