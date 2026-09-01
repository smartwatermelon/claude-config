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
overrides `CLAUDE_CONFIG_DIR`/the stored login.

**Practical constraint (confirmed by Andrew, 2026-09-01): a beacon-biosignals
repo is never opened on the personal machine, and this isn't something to
branch or code for.** That collapses condition 1 the same way condition 3
already collapses: the company machine's default identity is already
Beacon, so a beacon-biosignals repo never needs an explicit override either.
**The only case that ever needs an override is condition 2 happening on the
company machine** — opening a personal-org repo while on the company
machine, where the default identity would otherwise be wrong. Everything
below reflects that; the two-account, direction-dependent design from the
first pass of this doc is kept in an appendix for the research it captured,
not because it's still the plan.

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
`remote-control.md`, since this determines which mechanism is even
possible:

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
  Mandatory Protocol and hook this file describes, so the personal-side
  `CLAUDE_CONFIG_DIR` (see Design, below) needs those symlinked in from
  this repo the same way `install.sh` already does for `~/.claude`.

Remote Control matters here because it's a feature Andrew actively uses day
to day on the personal account, and the override case below needs to keep
it working. A `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) was
researched as a lighter-weight alternative to a full `CLAUDE_CONFIG_DIR`
split, but it can't establish Remote Control sessions — see the appendix.
That token mechanism turned out not to be needed once the beacon-on-
personal-machine case was ruled out (it was the only case where trading
away Remote Control cost nothing), but it's documented in case a similar
account-switching need comes up again without that constraint.

## Design

Only one case needs an override at all: opening a smartwatermelon- or
nightowlstudiollc-owned repo while on the company machine, where the
machine's default identity would otherwise be Beacon.

| Case | Mechanism |
|---|---|
| beacon-biosignals repo, on either machine | No override — the company machine's default is already Beacon, and this repo is never opened on the personal machine. |
| smartwatermelon/nightowlstudiollc repo, on the personal machine | No override — machine default is already personal, full Remote Control. |
| smartwatermelon/nightowlstudiollc repo, on the company machine | A `CLAUDE_CONFIG_DIR` split (hooks/skills/CLAUDE.md symlinked in from this repo, same as `~/.claude`) with a one-time interactive `claude login` as the personal account. Remote Control needs the full login here, not a token. |
| Neither (third-party org, no repo, no remote) | No override. |

That means the module's actual job is small: resolve the repo owner, and if
it's `smartwatermelon` or `nightowlstudiollc`, export
`CLAUDE_CONFIG_DIR=<personal config dir>`. Everything else is a no-op.
Whether the module should still recognize `beacon-biosignals` explicitly
(even though nothing currently needs it to act on that recognition) is an
open question below — the case for it is defense-in-depth if the "never
happens" constraint ever stops holding; the case against is not building
for a case that, per Andrew, will not occur.

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
  small config file lists which owners count as "personal" (today:
  `smartwatermelon`, `nightowlstudiollc`) and where the personal
  `CLAUDE_CONFIG_DIR` lives. This is what actually answers "associate
  repos/orgs with Anthropic accounts" as configuration rather than as
  branches buried in shell — adding a third personal-side org later is an
  edit to the config file, not the script. Exact format (pipe-delimited
  conf, small JSON, env-var block) is an open question for the next pass,
  not decided here.
- **One entry point**: given the current directory (or an explicit repo
  path), it either prints/exports `CLAUDE_CONFIG_DIR`, or emits nothing
  when no override applies. `bin/claude-wrapper` sources this module and
  calls that one function — a single integration point that's easy to
  unhook if the mechanism ever needs to change again.

## One-time setup (manual, not part of the module itself)

Needed once, on the company machine only. Create the personal-side
`CLAUDE_CONFIG_DIR` (symlink-bootstrap it from
this repo the way `install.sh` already does for `~/.claude`), then run an
interactive `claude login` under it once, as the personal account. Nothing
is needed on the personal machine — its default identity is already
correct for both of the cases that ever reach it.

## Open questions to resume with tomorrow

1. Exact mapping-config file format and location.
2. Whether the module should still recognize `beacon-biosignals` by name
   (even with no action tied to it today) for defense-in-depth, or should
   only encode the personal-owner set — see Design, above.
3. Whether to fold the `GH_TOKEN`/git-identity gaps (see Non-goals) into
   the same change or file them as separate follow-up work — leaning
   toward separate, to keep this module minimal and actually severable.
4. Test approach: unit-test the owner-resolution parsing against fake git
   remotes (mirroring `tests/test-wrapper.sh`'s existing style); the actual
   `CLAUDE_CONFIG_DIR`-switch behavior can only be verified by hand on the
   company machine.

## Appendix: the `CLAUDE_CODE_OAUTH_TOKEN` mechanism (researched, not used)

This was the first pass's answer for a "beacon-biosignals repo opened on
the personal machine" case that turned out not to exist. Keeping the
findings here since they're accurate facts about Claude Code's auth model
independent of this specific design, in case a similar need comes up later
without the "Remote Control doesn't matter for this account" out this
design has.

- `claude setup-token` mints a long-lived (1 year) OAuth token for
  `CLAUDE_CODE_OAUTH_TOKEN`. It's an interactive, browser-based, one-time
  mint per account — no `--json`/`--print` machine-readable output mode
  exists yet (open feature requests: anthropics/claude-code#48373,
  anthropics/claude-code#57400). Confirmed already in production use in
  this fleet: `claude-wrapper/.github/workflows/claude.yml` and
  `claude-blocking-review.yml` pass `secrets.CLAUDE_CODE_OAUTH_TOKEN`
  straight into a reusable workflow with zero manual login step.
- Precedence rule: **a stored `/login` credential in a given
  `CLAUDE_CONFIG_DIR` always wins over `CLAUDE_CODE_OAUTH_TOKEN`** set in
  that same process's environment. The token only takes effect in a config
  dir that has no stored login. This is exactly why the GitHub Actions
  case "just works" with no login step — a fresh runner's `~/.claude`
  never had a stored credential to lose to in the first place.
- `CLAUDE_CODE_OAUTH_TOKEN` (like an API key) cannot establish Remote
  Control sessions or fetch claude.ai connectors — those need a full-scope
  `/login` credential. It does not limit core coding functionality (Bash,
  Read/Write/Edit, locally-configured MCP servers all work) — only
  claude.ai-hosted features (Remote Control, Routines, Code Review-as-a-
  claude.ai-feature, the Chrome extension, remote connectors). Beacon
  already blocks Remote Control at the admin/account level regardless of
  auth mechanism, which is why this limitation was a non-issue for the
  Beacon side specifically.
- No CLI revoke for a minted setup-token exists yet; revocation happens
  only through the claude.ai web UI and can take up to ~4 days to actually
  invalidate the token server-side (anthropics/claude-code#43801). Treat a
  minted token as long-lived and handle it with the same care as `GH_TOKEN`.
