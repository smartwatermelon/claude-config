#!/usr/bin/env bash
# Hook: Block direct REST API calls to the GitHub PR merge endpoint
#
# Purpose:
#   The gh() wrapper in ~/.config/bash/functions.sh intercepts `gh pr merge`
#   and routes it through pre-merge-review.sh + merge-lock authorization.
#   However, `gh api .../pulls/NNN/merge --method PUT` bypasses the wrapper
#   entirely, circumventing all code quality gates.
#
#   This hook closes that gap by blocking the merge endpoint at the Claude
#   Code PreToolUse layer, before any Bash command is executed.
#
# Root cause documented in post-mortems:
#   - PR #813: gh pr merge failed silently → gh api used as workaround
#   - v1.11.0: pattern reused → 9-second unauthorized production merge
#
# If gh pr merge fails: report the failure, ask the human to merge manually.
# NEVER use gh api .../merge as a workaround.
#
# Called by: hook-block-all.sh (PreToolUse Bash hook chain)

set -euo pipefail

input=$(cat)
cmd=$(printf '%s\n' "${input}" | jq -r '.tool_input.command // empty')

# INDIRECT gh (smartwatermelon/dotfiles#339). The guards in dotfiles' gh-wrapper.sh (off-org --draft, merge review,
# REST/GraphQL bypass blocking) run only when bare `gh` resolves to the wrapper function or ~/.local/bin/gh.
# An absolute path to the real binary (/opt/homebrew/bin/gh) skips all of them, and an agent opened a
# non-draft off-org PR that way. GH_INDIRECT matches the forms that may not reach the wrapper: any path
# ending in /gh, `\gh`, and gh behind a prefix command (command, env, exec, nohup, sudo, time, xargs).
# GH_ANY is bare gh or any indirect form; the api rules below use it so an absolute path is caught too.
# Best effort, not complete: a regex is not a shell parser. `bash -c '...gh...'`, a variable holding the path,
# or an alias still get past it. GH_PREFIX takes one optional argument per option (`sudo -u root gh`).
# CP is the command-position anchor (see claude-config#405 below), plus `(` for a subshell. ASSIGN allows
# leading VAR=value words, e.g. `GH_TOKEN=... /opt/homebrew/bin/gh pr merge 1`. GF is the global-flag run.
CP='(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*|[`]|\$\(|\()[[:space:]]*'
ASSIGN='([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GF='(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*'
GH_PATH="[\"']?[^[:space:];&|()\`\"']*/gh[\"']?"
GH_PREFIX='(command|env|exec|nohup|sudo|time|xargs)[[:space:]]+(-[^[:space:]]*[[:space:]]+([^-/[:space:]][^[:space:]]*[[:space:]]+)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
GH_INDIRECT="(${GH_PREFIX}(${GH_PATH}|gh)|${GH_PATH}|\\\\gh)"
GH_ANY="(gh|${GH_INDIRECT})"
CP="${CP}${ASSIGN}"

# Early-exempt: git commit/log/show/diff invocations without a chained gh
# call. Their arguments (commit messages, log output, diff text) may
# legitimately contain the literal patterns matched below — a commit
# message explaining that `gh api graphql --input` is blocked must be
# allowed. This hook can't separate command text from quoted argument
# text, so it relies on two conditions:
#   1. The primary verb is git (commit|log|show|diff) at cmd start.
#   2. No gh invocation appears after a shell-operator boundary — start
#      of command, ; & |, or the command-substitution openers ( and `.
#      A literal mention of gh inside quoted text is not preceded by
#      any of these, so it doesn't trigger the guard, but $(gh ...) or
#      `gh ...` substitution does (and must still be blocked).
# Net: `git commit -m "... gh api ..."` is exempted, but
# `git diff && gh api .../merge` is NOT (the gh after && is a real call).
# `git diff` followed by a literal-newline-chained `gh api .../merge` (no
# leading shell operator on its own line) is ALSO not exempted (#137): an
# unindented line 2+ that starts with `gh` is a real statement, not quoted
# argument text. Indented lines (e.g. inside a heredoc body) don't match,
# so the exemption for quoted commit-message text is preserved. Line 1 is
# excluded from this check (via `tail -n +2`) because for this exemption
# block the primary verb is `git`, not `gh`, so line 1 never legitimately
# starts with `gh` anyway — but excluding it keeps the check symmetric
# with the gh-pr|issue-create exemption below.
if printf '%s\n' "${cmd}" | grep -qE '^[[:space:]]*git[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*(commit|log|show|diff)([[:space:]]|$)' \
  && ! printf '%s\n' "${cmd}" | grep -qE "[;&|(\`][[:space:]]*${ASSIGN}${GH_ANY}[[:space:]]+" \
  && ! printf '%s\n' "${cmd}" | tail -n +2 | grep -qE "^${ASSIGN}${GH_ANY}[[:space:]]+"; then
  exit 0
fi

# Early-exempt: gh pr|issue create|edit|comment invocations whose text args
# (--body, --title, --message) may legitimately contain trigger patterns
# (discovered during Batch D — I had to reword a PR body to avoid false-
# positive on the literal gh api graphql --input mention). Fires only when:
#   1. The primary verb is gh (pr|issue) (create|edit|comment), with optional
#      interposed flags (-R owner/repo, --repo owner/repo, etc.) between gh
#      and the subcommand.
#   2. No OTHER gh call appears after a shell-operator boundary (; & | ( `).
#      The leading gh is at command start and is not preceded by an operator,
#      so only chained follow-on gh calls match the negation regex.
# Net: `gh pr create --body "... gh api graphql --input ..."` is exempted,
# but `gh pr create --body "..." && gh api .../merge` is NOT.
# `gh pr create ...` followed by a literal-newline-chained `gh api .../merge`
# is ALSO not exempted (#137). Line 1 (the primary `gh pr|issue ...`
# invocation itself, which legitimately starts with `gh`) is excluded from
# the unindented-line check via `tail -n +2`, so only genuine follow-on
# lines starting with `gh` at column 0 trip the negation.
if printf '%s\n' "${cmd}" | grep -qE '^[[:space:]]*gh[[:space:]]+(-[^[:space:]]+[[:space:]]+([^-][^|;&[:space:]]*[[:space:]]+)?)*(pr|issue)[[:space:]]+(create|edit|comment)([[:space:]]|$)' \
  && ! printf '%s\n' "${cmd}" | grep -qE "[;&|(\`][[:space:]]*${ASSIGN}${GH_ANY}[[:space:]]+" \
  && ! printf '%s\n' "${cmd}" | tail -n +2 | grep -qE "^${ASSIGN}${GH_ANY}[[:space:]]+"; then
  exit 0
fi

# COMMAND-POSITION ANCHOR (claude-config#405). The four api matchers below
# require the tool name at a command position -- start of line, or
# immediately after a shell operator, backtick, or command substitution --
# rather than anywhere in the string. `^` covers the line case on its own:
# grep matches per line and the command is piped through printf '%s\n'.
# Without it the endpoint matched inside a quoted argument being written to
# a file, so writing a test fixture for this hook was blocked by this hook.
# Same idiom the pr-merge matcher further down already used.
#
# The backtick is spelled [`], not \`: GNU grep reads \` as its
# start-of-buffer anchor, so on Linux a backtick-substituted gh api call
# went unblocked. BSD grep reads both as a literal backtick.
#
# KNOWN GAP, accepted: a heredoc body starts at a line boundary, so a
# heredoc containing the endpoint still matches. Distinguishing a heredoc
# body from a command needs real tokenization, which a PreToolUse hook
# operating on an unexpanded string cannot do. This is the same
# regex-is-not-a-shell-parser limit recorded for the false-NEGATIVE
# direction in #349, and it fails safe: the cost is a blocked write, not a
# permitted merge.
# Block: gh api .../pulls/{number}/merge  (REST endpoint)
# Suffix boundary ([[:space:]]|$|[^[:alnum:]_]) prevents false positives on
# hypothetical paths like pulls/NNN/merge_status while still matching:
#   gh api repos/owner/repo/pulls/123/merge --method PUT
#   gh api /repos/owner/repo/pulls/123/merge
#   gh api "repos/owner/repo/pulls/123/merge"
#   echo x && gh api repos/o/r/pulls/1/merge --method PUT
if printf '%s\n' "${cmd}" | grep -qE "${CP}${GH_ANY}[[:space:]]+${GF}"'api[[:space:]].*pulls/[0-9]+/merge([[:space:]]|$|[^[:alnum:]_])'; then
  printf '%s BLOCKED API MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: Direct REST API PR merge bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf 'This endpoint skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` instead — it routes through pre-merge-review.sh.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use the REST API as a workaround.\n' >&2
  exit 2
fi

# Block: gh api graphql with mergePullRequest mutation
# GraphQL offers the same merge capability as the REST endpoint above.
# Covers inline mutations passed via -f query=... or --field query=...
if printf '%s\n' "${cmd}" | grep -qE "${CP}${GH_ANY}[[:space:]]+${GF}"'api[[:space:]].*graphql.*mergePullRequest'; then
  printf '%s BLOCKED GRAPHQL MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: GraphQL mergePullRequest mutation bypasses code quality gates.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` instead — it routes through pre-merge-review.sh.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh api graphql --input (any form)
# --input reads the GraphQL mutation from a file or stdin, so the command-line
# scanners above cannot inspect the mutation body. Since the only reason to
# use --input for Claude-initiated gh calls is to hide the payload from
# linting, block this pattern unconditionally. Legitimate data queries
# rarely need --input; they can be expressed inline via -f query=.
# Previously documented as a known gap (Protocol 6 in CLAUDE.md) — now closed.
if printf '%s\n' "${cmd}" | grep -qE "${CP}${GH_ANY}[[:space:]]+${GF}"'api[[:space:]].*graphql.*(--input([[:space:]=]|$)|(-F|--field)[[:space:]=]*input)'; then
  printf '%s BLOCKED GRAPHQL --input: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh api graphql --input reads the mutation from a file,\n' >&2
  printf '   hiding its contents from the command-line merge-bypass scanners.\n' >&2
  printf '\n' >&2
  printf "If you are trying to merge a PR, use \`gh pr merge <number>\` instead.\n" >&2
  printf 'If you need a legitimate GraphQL query, pass it inline via -f query=.\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh api graphql with -f/-F/--field name=@file  (value-from-file)
# gh'"'"'s @<filename> convention for -f / --field reads the value from a file,
# which lets a mutation body live on disk and still get executed. Covers the
# gap left by the --input check above. Issue #133.
if printf '%s\n' "${cmd}" | grep -qE "${CP}${GH_ANY}[[:space:]]+${GF}"'api[[:space:]].*graphql.*(-[fF]|--field)[[:space:]=]*(query|mutation)[[:space:]]*=[[:space:]]*@'; then
  printf '%s BLOCKED GRAPHQL @file: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh api graphql with -f/-F query=@<file> (or mutation=@<file>)\n' >&2
  printf '   reads the payload body from a file via gh'"'"'s @<filename> convention,\n' >&2
  printf '   hiding its contents from the command-line merge-bypass scanners.\n' >&2
  printf '\n' >&2
  printf "If you are trying to merge a PR, use \`gh pr merge <number>\` instead.\n" >&2
  printf 'If you need a legitimate GraphQL query, pass it inline via -f query=<body> (no @).\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Block: gh [global-flags] pr merge (global-flag prefix bypass)
# When global flags like -R/--repo appear before the subcommand, the gh() bash
# wrapper's positional check ($1=='pr' && $2=='merge') is skipped entirely,
# allowing a merge without pre-merge review or merge-lock authorization.
#
# The leading anchor requires 'gh' to appear at the start of a line or after an
# explicit shell operator (&&, ||, ;, |, &), so 'gh -R' text embedded in commit
# messages or quoted strings does not produce false positives.
# Operators are matched explicitly (&&, ||) or as single characters (;, |, &)
# to avoid the brittleness of relying on accidental single-character matching.
if printf '%s\n' "${cmd}" | grep -qE '(^|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*|[|&][[:space:]]*)gh[[:space:]]+-[^[:space:]].*[[:space:]]pr[[:space:]]+merge([[:space:]]|$)'; then
  printf '%s BLOCKED GLOBAL FLAG MERGE BYPASS: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh pr merge with global flags (e.g. -R repo) bypasses shell wrapper routing.\n' >&2
  printf '\n' >&2
  printf 'Placing global flags before the subcommand skips pre-merge review and merge authorization.\n' >&2
  printf '\n' >&2
  printf "Use \`gh pr merge <number>\` (no global flags before the subcommand) instead.\n" >&2
  printf '\n' >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  printf 'Do NOT use global flag placement as a workaround.\n' >&2
  exit 2
fi

# Block: indirect gh pr merge (smartwatermelon/dotfiles#339)
# `/opt/homebrew/bin/gh pr merge N` never reaches the wrapper, so pre-merge-review.sh and the merge-lock
# check do not run. Bare `gh pr merge` is left to the wrapper, as before.
if printf '%s\n' "${cmd}" | grep -qE "${CP}${GH_INDIRECT}[[:space:]]+${GF}pr[[:space:]]+merge([[:space:]]|\$)"; then
  printf '%s BLOCKED INDIRECT GH MERGE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
  printf '🛑 BLOCKED: gh pr merge through a path or prefix command skips the gh wrapper.\n' >&2
  printf '\n' >&2
  printf 'The real binary at an absolute path runs no pre-merge review and no merge-lock check.\n' >&2
  printf "Use plain \`gh pr merge <number>\` so the wrapper runs.\n" >&2
  printf 'If gh pr merge is failing, report the failure and ask the human to merge manually.\n' >&2
  exit 2
fi

# Segments for the indirect-create, pr-ready and api-pulls rules below (smartwatermelon/dotfiles#339).
# Backslash-newline continuations are joined first so a flag on a later line is seen. Then: unquote a quoted gh
# path, a quoted pulls endpoint, POST and draft=true; replace other quoted strings with Q (a --body may hold ; or
# --draft); and turn every operator into a newline so each command is on its own line.
joined="${cmd//$'\\\n'/ }"
split=$(printf '%s\n' "${joined}" \
  | sed -E "s#[\"']([^\"'[:space:]]*/gh)[\"']#\\1#g; s#[\"'](/?repos/[^\"'[:space:]]+/pulls)[\"']#\\1#g; s#[\"']([Pp][Oo][Ss][Tt]|draft=true)[\"']#\\1#g; s/\"[^\"]*\"/Q/g; s/'[^']*'/Q/g" \
  | tr ';&|()`' '\n')
seg_re="^[[:space:]]*${ASSIGN}${GH_INDIRECT}[[:space:]]+${GF}"

# Block: indirect gh pr create without --draft
# The wrapper forces --draft for an off-org repo. The real binary does not, and this hook cannot tell
# in-org from off-org without resolving the repo, so an indirect create must carry --draft (or -d)
# itself. Quoted text is removed before the flag check, so "--draft" inside --body does not count.
# `gh pr new` is an alias of `gh pr create`, so both are matched.
create_re="${CP}${GH_INDIRECT}[[:space:]]+${GF}pr[[:space:]]+(create|new)([[:space:]]|\$)"
if printf '%s\n' "${joined}" | grep -qE "${create_re}"; then
  # Each indirect create must have --draft. If no segment still holds one, the match was inside quoted
  # text that may be a $(...) or backtick: block that too.
  draft_ok=1
  seen=0
  while IFS= read -r seg; do
    printf '%s\n' "${seg}" | grep -qE "${seg_re}pr[[:space:]]+(create|new)([[:space:]]|\$)" || continue
    seen=1
    seg=$(printf '%s\n' "${seg}" | sed -E 's/^.*pr[[:space:]]+(create|new)//')
    if ! printf '%s\n' "${seg}" | grep -qE '(^|[[:space:]])(--draft|--draft=true|-d)([[:space:]]|$)'; then
      draft_ok=0
    fi
  done <<<"${split}"
  [[ "${seen}" == "1" ]] || draft_ok=0
  if [[ "${draft_ok}" == "0" ]]; then
    printf '%s BLOCKED INDIRECT GH CREATE: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
    printf '🛑 BLOCKED: gh pr create through a path or prefix command skips the gh wrapper.\n' >&2
    printf '\n' >&2
    printf 'The wrapper forces --draft for a repo outside smartwatermelon, nightowlstudiollc and\n' >&2
    printf 'twistedmelonman. The real binary does not, so this call could open a non-draft PR.\n' >&2
    printf "Use plain \`gh pr create ...\` so the wrapper runs.\n" >&2
    printf "The real binary is for read-only checks only, e.g. \`/opt/homebrew/bin/gh api user --jq .login\`.\n" >&2
    exit 2
  fi
fi

# New rules block an unseen match (all quoted) only if the command holds a $( or backtick that could run it.
has_subst=0
[[ "${joined}" == *"\$("* ||"${joined}" == *'`'* ]] && has_subst=1

# Block: indirect gh pr ready without --undo
# The wrapper refuses `pr ready` for an off-org repo. The real binary does not, so an indirect call could
# take an off-org draft out of draft. `--undo` returns a PR to draft, which is safe.
ready_re="${CP}${GH_INDIRECT}[[:space:]]+${GF}pr[[:space:]]+ready([[:space:]]|\$)"
if printf '%s\n' "${joined}" | grep -qE "${ready_re}"; then
  ready_ok=1
  seen=0
  while IFS= read -r seg; do
    printf '%s\n' "${seg}" | grep -qE "${seg_re}pr[[:space:]]+ready([[:space:]]|\$)" || continue
    seen=1
    printf '%s\n' "${seg}" | grep -qE '(^|[[:space:]])--undo([[:space:]]|$)' || ready_ok=0
  done <<<"${split}"
  [[ "${seen}" == "1" || "${has_subst}" == "0" ]] || ready_ok=0
  if [[ "${ready_ok}" == "0" ]]; then
    printf '%s BLOCKED INDIRECT GH READY: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
    printf '🛑 BLOCKED: gh pr ready through a path or prefix command skips the gh wrapper.\n' >&2
    printf '\n' >&2
    printf "The wrapper refuses \`pr ready\` for an off-org repo. The real binary does not.\n" >&2
    printf "Use plain \`gh pr ready\` so the wrapper runs. (\`--undo\`, back to draft, is allowed.)\n" >&2
    exit 2
  fi
fi

# Block: indirect gh api that creates a PR without draft=true
# POST repos/<o>/<r>/pulls opens a PR and skips the wrapper's off-org draft forcing. POST is explicit (-X/--method)
# or implicit (-f/-F/--field/--raw-field/--input with no explicit method). Only the exact endpoint counts: GET on it
# and pulls/<n>/... subpaths are untouched. A field must set draft=true; --input hides the body, so it is blocked.
api_re="${CP}${GH_INDIRECT}[[:space:]]+${GF}api[[:space:]]"
if printf '%s\n' "${joined}" | grep -qE "${api_re}"; then
  api_ok=1
  seen=0
  pulls_ep='(^|[[:space:]])/?repos/[^/[:space:]]+/[^/[:space:]]+/pulls(\?[^[:space:]]*)?/?([[:space:]]|$)'
  method_re='(^|[[:space:]])(-X|--method)[[:space:]=]*([A-Za-z]+)'
  field_re='(^|[[:space:]])(-[fF]|--field|--raw-field|--input)'
  draft_re='(^|[[:space:]])(-[fF]|--field|--raw-field)[[:space:]=]*draft=true([[:space:]]|$)'
  while IFS= read -r seg; do
    printf '%s\n' "${seg}" | grep -qE "${seg_re}api[[:space:]]" || continue
    seen=1
    seg=$(printf '%s\n' "${seg}" | sed -E 's/^.*[[:space:]]api[[:space:]]/ /')
    [[ "${seg}" =~ ${pulls_ep} ]] || continue
    if [[ "${seg}" =~ ${method_re} ]]; then
      is_post=0
      [[ "${BASH_REMATCH[3]^^}" == "POST" ]] && is_post=1
    elif [[ "${seg}" =~ ${field_re} ]]; then
      is_post=1
    else
      is_post=0
    fi
    [[ "${is_post}" == "1" ]] || continue
    [[ "${seg}" =~ ${draft_re} ]] || api_ok=0
  done <<<"${split}"
  [[ "${seen}" == "1" || "${has_subst}" == "0" ]] || api_ok=0
  if [[ "${api_ok}" == "0" ]]; then
    printf '%s BLOCKED INDIRECT GH API PULLS: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ || true)" "${cmd}" >>"${HOME}/.claude/blocked-commands.log" || true
    printf '🛑 BLOCKED: gh api POST repos/<owner>/<repo>/pulls through a path or prefix command skips the gh wrapper.\n' >&2
    printf '\n' >&2
    printf 'The wrapper forces a draft PR for an off-org repo. The real binary does not.\n' >&2
    printf "Add \`-F draft=true\` to the call, or use plain \`gh pr create\` so the wrapper runs.\n" >&2
    exit 2
  fi
fi
