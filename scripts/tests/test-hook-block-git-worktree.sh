#!/usr/bin/env bash
# Tests for hook-block-git-worktree.sh

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-git-worktree.sh"
pass=0
fail=0

check() {
  local desc="${1}" expected="${2}" input="${3}" actual
  actual=0
  printf '%s\n' "${input}" | "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

make_input() {
  jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

echo "=== hook-block-git-worktree tests ==="

# Should BLOCK (exit 2) — unscoped creation, administrative subcommands,
# bare worktree, unknown subcommands
inp="$(make_input 'git worktree add /tmp/wt feature')"
check "creation outside scope (/tmp)" 2 "${inp}"
inp="$(make_input 'git worktree move /tmp/wt /tmp/wt2')"
check "git worktree move" 2 "${inp}"
inp="$(make_input 'git worktree lock /tmp/wt')"
check "git worktree lock" 2 "${inp}"
inp="$(make_input 'git worktree unlock /tmp/wt')"
check "git worktree unlock" 2 "${inp}"
inp="$(make_input 'git worktree repair')"
check "git worktree repair" 2 "${inp}"
inp="$(make_input 'git worktree')"
check "bare git worktree (no subcommand)" 2 "${inp}"
inp="$(make_input 'git worktree unknownfuturesubcommand')"
check "git worktree unknown subcommand (fail closed)" 2 "${inp}"
inp="$(make_input 'git -C /some/path worktree add /tmp/wt')"
check "git -C /path, unscoped creation" 2 "${inp}"
inp="$(make_input 'git --no-pager worktree add /tmp/wt')"
check "git --no-pager, unscoped creation" 2 "${inp}"
inp="$(make_input 'cd /repo && git worktree add /tmp/wt')"
check "chained: cd && unscoped creation" 2 "${inp}"

# --- dotfiles#200: cleanup subcommands are now ALLOWED ---
# These only ever reduce worktree count, so they cannot reintroduce the
# collisions the original ban existed to prevent.
inp="$(make_input 'git worktree remove .claude/worktrees/agent-abc')"
check "cleanup: remove (now allowed)" 0 "${inp}"
inp="$(make_input 'git worktree prune')"
check "cleanup: prune (now allowed)" 0 "${inp}"
inp="$(make_input 'git worktree remove /tmp/some-stale-wt')"
check "cleanup: remove of an out-of-scope stale worktree (allowed)" 0 "${inp}"
inp="$(make_input 'git -C /some/repo worktree prune')"
check "cleanup: prune with interposed -C flag" 0 "${inp}"
# `remove` refuses when the worktree has untracked files, so real cleanup of an
# agent worktree (whose post-checkout setup generates files) needs --force.
# Verified against a live create/remove cycle; blocking this would leave the
# un-cleanable-worktree problem from dotfiles#200 only half fixed.
inp="$(make_input 'git worktree remove --force .claude/worktrees/agent-abc')"
check "cleanup: remove --force (required for dirty worktrees)" 0 "${inp}"
inp="$(make_input 'git worktree prune --dry-run')"
check "cleanup: prune --dry-run" 0 "${inp}"
# ACCEPTED TRADE-OFF (#347): cleanup is deliberately NOT path-scoped, so the
# forceful out-of-scope form -- the one that can destroy a peer agent's
# worktree and its uncommitted work -- is allowed too. Pinned so that adding
# path-scoping to `remove` trips a test instead of silently re-breaking the
# pre-ban cleanup case dotfiles#200 fixed. See the header's ACCEPTED TRADE-OFF
# note before changing this expectation.
inp="$(make_input 'git worktree remove --force /tmp/other-agents-worktree')"
check "cleanup: forceful out-of-scope remove (deliberately allowed, #347)" 0 "${inp}"

# --- dotfiles#200: creation ALLOWED only under .claude/worktrees/ ---
inp="$(make_input 'git worktree add .claude/worktrees/agent-abc123')"
check "creation: scoped relative path" 0 "${inp}"
inp="$(make_input 'git worktree add ./.claude/worktrees/agent-abc123')"
check "creation: scoped ./ relative path" 0 "${inp}"
inp="$(make_input 'git worktree add /Users/me/Developer/repo/.claude/worktrees/wt1')"
check "creation: scoped absolute path" 0 "${inp}"
inp="$(make_input 'git worktree add -b claude/my-feature .claude/worktrees/wt1')"
check "creation: scoped with -b branch before path" 0 "${inp}"
inp="$(make_input 'git worktree add --detach .claude/worktrees/wt1')"
check "creation: scoped with valueless flag" 0 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees/wt1 HEAD~2')"
check "creation: scoped with trailing commit-ish" 0 "${inp}"
inp="$(make_input 'git -C /some/repo worktree add .claude/worktrees/wt1')"
check "creation: scoped with interposed -C flag" 0 "${inp}"

# Creation rejections: the path must be PROVABLY in scope.
inp="$(make_input 'git worktree add ../elsewhere/.claude/worktrees/wt1')"
check "creation: rejects leading .. traversal" 2 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees/../../escape')"
check "creation: rejects embedded .. traversal" 2 "${inp}"
# The literal dollar sign is assembled rather than written inline: the hook must
# see an UNEXPANDED variable reference, which is precisely what this asserts.
dollar='$'
inp="$(make_input "git worktree add ${dollar}HOME/.claude/worktrees/wt1")"
check "creation: rejects unexpanded variable reference" 2 "${inp}"
inp="$(make_input 'git worktree add ~/.claude/worktrees/wt1')"
check "creation: rejects unexpanded ~" 2 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees/*')"
check "creation: rejects glob" 2 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees')"
check "creation: rejects bare scope dir with no leaf" 2 "${inp}"
inp="$(make_input 'git worktree add')"
check "creation: rejects missing path" 2 "${inp}"
inp="$(make_input 'git worktree add -b claude/feature')"
check "creation: rejects -b consuming the only operand" 2 "${inp}"
inp="$(make_input 'git worktree add /tmp/.claude/worktreesevil/wt1')"
check "creation: rejects scope-lookalike prefix" 2 "${inp}"
inp="$(make_input 'git worktree add notclaude/worktrees/wt1')"
check "creation: rejects non-scope path" 2 "${inp}"

# A scoped creation must not launder a mutating sibling in a compound command.
inp="$(make_input 'git worktree add .claude/worktrees/ok && git worktree move /a /b')"
check "compound: scoped add && move (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees/ok && git worktree add /tmp/bad')"
check "compound: scoped add && unscoped add (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree add .claude/worktrees/a && git worktree remove .claude/worktrees/b')"
check "compound: scoped add && remove (both allowed)" 0 "${inp}"

# Should PASS (exit 0) — read-only/inspection subcommands
inp="$(make_input 'git worktree list')"
check "git worktree list" 0 "${inp}"
inp="$(make_input 'git worktree --help')"
check "git worktree --help" 0 "${inp}"
inp="$(make_input 'git worktree -h')"
check "git worktree -h" 0 "${inp}"
inp="$(make_input 'git -C /some/path worktree list')"
check "git -C /path worktree list (interposed flag)" 0 "${inp}"
inp="$(make_input 'cd /repo && git worktree list')"
check "chained: cd && git worktree list" 0 "${inp}"
inp="$(make_input 'git commit -m msg')"
check "git commit" 0 "${inp}"
inp="$(make_input 'git checkout -b worktree-fix')"
check "git checkout -b worktree-fix" 0 "${inp}"
inp="$(make_input 'echo git worktree is blocked')"
check "echo about worktree" 0 "${inp}"
inp="$(make_input 'brew update')"
check "unrelated command" 0 "${inp}"

# Additional operator-chaining cases (read-only allowed through even when chained)
inp="$(make_input 'ls; git worktree list')"
check "chained: ; git worktree list" 0 "${inp}"
inp="$(make_input 'true || git worktree list')"
check "chained: || git worktree list" 0 "${inp}"
inp="$(make_input 'echo x | git worktree list')"
check "chained: | git worktree list" 0 "${inp}"

# Additional operator-chaining BLOCK cases (mutating still blocked when chained)
inp="$(make_input 'ls; git worktree add /tmp/wt')"
check "chained: ; git worktree add" 2 "${inp}"
inp="$(make_input 'true || git worktree prune')"
check "chained: || git worktree prune (cleanup, now allowed)" 0 "${inp}"
inp="$(make_input 'true || git worktree move /a /b')"
check "chained: || git worktree move (still blocked)" 2 "${inp}"
inp="$(make_input 'echo x | git worktree add')"
check "chained: | git worktree add" 2 "${inp}"

# False-positive guard: git grep searching for "worktree" string
inp="$(make_input 'git grep worktree')"
check "git grep worktree (not blocked)" 0 "${inp}"

# Multi-invocation compound commands: a read-only occurrence must not mask a
# mutating one elsewhere in the same command string (regression for the
# single-match bypass caught in PR review — see smartwatermelon/claude-config#268).
inp="$(make_input 'git worktree list && git worktree add /tmp/wt')"
check "compound: list && add (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list | git worktree add /tmp/wt')"
check "compound: list | add (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree add /tmp/wt && git worktree list')"
check "compound: add && list, mutating first (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list ; git worktree lock /tmp/wt')"
check "compound: list ; lock (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list ; git worktree remove /tmp/wt')"
check "compound: list ; remove (cleanup, now allowed)" 0 "${inp}"
inp="$(make_input 'git worktree list && git worktree --help')"
check "compound: list && --help, both read-only (must pass)" 0 "${inp}"

# --- Separator coverage (closed by the dotfiles#200 review) ---
# These forms previously evaded the matcher entirely, which mattered more once
# `add` became a conditional allow: an unmatched occurrence skips path scoping.
inp="$(make_input 'git worktree list & git worktree add /tmp/evil')"
check "separator: & backgrounding" 2 "${inp}"
inp="$(make_input '(git worktree add /tmp/evil)')"
check "separator: subshell parens" 2 "${inp}"
inp="$(make_input 'git status && (git worktree add /tmp/evil)')"
check "separator: subshell after &&" 2 "${inp}"
inp="$(make_input '{ git worktree add /tmp/evil; }')"
check "separator: brace group" 2 "${inp}"
inp="$(make_input 'if true; then git worktree add /tmp/evil; fi')"
check "separator: then keyword" 2 "${inp}"
inp="$(make_input 'for i in 1; do git worktree add /tmp/evil; done')"
check "separator: do keyword" 2 "${inp}"
# Scoped creation must still be allowed through the newly-recognized separators.
inp="$(make_input '(git worktree add .claude/worktrees/ok)')"
check "separator: subshell with scoped path (allowed)" 0 "${inp}"

# --- Wrapped / path-prefixed invocation (also closed by the review) ---
inp="$(make_input "echo ${dollar}(git worktree add /tmp/evil)")"
check "wrapper: command substitution" 2 "${inp}"
inp="$(make_input '/usr/bin/git worktree add /tmp/evil')"
check "wrapper: absolute-path git" 2 "${inp}"
inp="$(make_input 'env git worktree add /tmp/evil')"
check "wrapper: env-prefixed git" 2 "${inp}"
inp="$(make_input 'command git worktree add /tmp/evil')"
check "wrapper: command-prefixed git" 2 "${inp}"
inp="$(make_input 'sudo git worktree add /tmp/evil')"
check "wrapper: sudo-prefixed git" 2 "${inp}"
inp="$(make_input '/usr/bin/git worktree add .claude/worktrees/ok')"
check "wrapper: absolute-path git, scoped path (allowed)" 0 "${inp}"

# False-positive guards for the wrapper/path-prefix alternatives above: a bare
# word merely ENDING in `git` must not match (the prefix requires a `/`).
inp="$(make_input 'mygit worktree add /tmp/x')"
check "false positive: mygit is not git" 0 "${inp}"
inp="$(make_input 'echo not-git worktree stuff')"
check "false positive: hyphenated word containing git" 0 "${inp}"

# --- Backtick command substitution (was a pinned KNOWN GAP; now closed) ---
# The backtick is a separator alternative, and also terminates the captured
# argument list so the closing backtick is not swallowed into the path token.
backtick='`'
inp="$(make_input "echo ${backtick}git worktree add /tmp/evil${backtick}")"
check "backtick substitution: unscoped creation blocked" 2 "${inp}"
inp="$(make_input "echo ${backtick}git worktree move /tmp/a /tmp/b${backtick}")"
check "backtick substitution: administrative subcommand blocked" 2 "${inp}"
# The closing backtick must not contaminate the path, or a scoped target would
# be read as `.claude/worktrees/ok\`` and wrongly rejected.
inp="$(make_input "echo ${backtick}git worktree add .claude/worktrees/ok${backtick}")"
check "backtick substitution: scoped creation allowed" 0 "${inp}"
inp="$(make_input "echo ${backtick}git worktree list${backtick}")"
check "backtick substitution: read-only subcommand allowed" 0 "${inp}"

# --- Quote-prefixed git (was a silently open gap; now closed) ---
# `git` placed after an opening quote rather than a separator matched none of
# the alternation, so path_in_scope() never ran. Covers single, double, and
# ANSI-C quoting; `eval` is included because it is the common vehicle.
sq="'"
dq='"'
inp="$(make_input "bash -c ${sq}git worktree add /tmp/evil${sq}")"
check "quote prefix: single-quoted unscoped creation blocked" 2 "${inp}"
inp="$(make_input "bash -c ${dq}git worktree add /tmp/evil${dq}")"
check "quote prefix: double-quoted unscoped creation blocked" 2 "${inp}"
inp="$(make_input "bash -c ${dollar}${sq}git worktree add /tmp/evil${sq}")"
check "quote prefix: ANSI-C quoted unscoped creation blocked" 2 "${inp}"
inp="$(make_input "eval ${sq}git worktree add /tmp/evil${sq}")"
check "quote prefix: eval-wrapped unscoped creation blocked" 2 "${inp}"
inp="$(make_input "bash -c ${sq}git worktree move /tmp/a /tmp/b${sq}")"
check "quote prefix: administrative subcommand blocked" 2 "${inp}"
# Scoped targets must still pass, and a quoted path must not be contaminated by
# its own quotes -- otherwise legitimate quoted creation would be rejected.
inp="$(make_input "bash -c ${sq}git worktree add .claude/worktrees/ok${sq}")"
check "quote prefix: scoped creation allowed" 0 "${inp}"
inp="$(make_input "git worktree add ${dq}.claude/worktrees/ok${dq}")"
check "quote prefix: quoted scoped path still allowed" 0 "${inp}"
inp="$(make_input "bash -c ${sq}git worktree list${sq}")"
check "quote prefix: read-only subcommand allowed" 0 "${inp}"

# --- Heredocs: already blocked, asserted so nobody "fixes" a non-gap ---
# grep -oE matches per line, so a heredoc body's `git` sits at line start and
# the `^` alternative catches it. Issue #349 claimed heredocs were a bypass;
# they are not. Pinned so that claim cannot be reintroduced as a change.
heredoc_cmd=$(printf 'cat <<EOF\ngit %s add /tmp/evil\nEOF' 'worktree')
inp="$(make_input "${heredoc_cmd}")"
check "heredoc body is matched at line start (not a bypass)" 2 "${inp}"
# --- Backslash in a path (read -r -a does not honor the escape) ---
# `read -r -a` splits on IFS without honoring backslash escapes, so
# `.claude/worktrees/my\\ evil` arrives as two tokens and only the first reaches
# path_in_scope(). That token IS a valid in-scope prefix, so the hook would
# approve it -- while the shell goes on to create `.claude/worktrees/my evil`,
# a different path than the one validated. Refused rather than approximated.
bs='\\'
inp="$(make_input "git worktree add .claude/worktrees/my${bs} evil")"
check "backslash: escaped space in an in-scope path is refused" 2 "${inp}"
inp="$(make_input "git worktree add /tmp/my${bs} evil")"
check "backslash: escaped space in an out-of-scope path is refused" 2 "${inp}"
inp="$(make_input "git worktree add .claude/worktrees/plain")"
check "backslash: an unescaped scoped path is still allowed" 0 "${inp}"

# --- Quoted MENTION vs quoted INVOCATION (#371) ---
# Making the quote a separator (so `bash -c 'git worktree add ...'` is
# inspected) also matched a quoted string that merely CONTAINS the phrase.
# `echo` and `grep` of the phrase were blocked despite executing nothing, which
# made writing docs and tests about this hook impossible.
#
# The captured match is identical either way -- quote, phrase, quote -- so the
# discriminator is the command PRECEDING the quote. Only a shell or `eval` runs
# the string. The lookback skips flags (`bash -c` puts `-c` next to the quote)
# and the ANSI-C `$` sigil.
inp="$(make_input "echo ${dq}git worktree add /tmp/x${dq}")"
check "mention: echo of a creation string is not an invocation" 0 "${inp}"
inp="$(make_input "echo ${dq}git worktree list${dq}")"
check "mention: echo of a read-only string is not an invocation" 0 "${inp}"
inp="$(make_input "grep -r ${dq}git worktree add${dq} docs/")"
check "mention: grep for the phrase in docs is allowed" 0 "${inp}"
inp="$(make_input "printf '%s' ${dq}git worktree move a b${dq}")"
check "mention: printf of an admin string is allowed" 0 "${inp}"

# The executor forms must still block -- this is the half that must not regress.
inp="$(make_input "sh -c ${sq}git worktree add /tmp/evil${sq}")"
check "invocation: sh -c still blocks despite the mention carve-out" 2 "${inp}"
inp="$(make_input "bash -c ${dq}git worktree add /tmp/evil${dq}")"
check "invocation: bash -c double-quoted still blocks" 2 "${inp}"
inp="$(make_input "eval ${dq}git worktree add /tmp/evil${dq}")"
check "invocation: eval double-quoted still blocks" 2 "${inp}"
# Wrappers that leave a shell adjacent to the quote must still block -- these
# are the forms that actually occur.
inp="$(make_input "sudo bash -c ${dq}git worktree add /tmp/evil${dq}")"
check "invocation: sudo bash -c still blocks" 2 "${inp}"
inp="$(make_input "command bash -c ${dq}git worktree add /tmp/evil${dq}")"
check "invocation: command bash -c still blocks" 2 "${inp}"
# KNOWN GAP, pinned as CURRENT behavior: a wrapper whose last non-flag word is
# not itself an executor (`pyenv exec`) is read as a mention and skipped. See
# the KNOWN LIMITATION note above _executes_quoted_string for why closing this
# would re-break the echo/grep false positive.
inp="$(make_input "pyenv exec ${dq}git worktree add /tmp/evil${dq}")"
check "KNOWN GAP: non-executor wrapper word is read as a mention" 0 "${inp}"

# --- PERMANENTLY OPEN gaps, asserted as CURRENT behavior, not desired ---
# Documented in the KNOWN LIMITATION block in the hook header. A PreToolUse
# hook sees the raw, unexpanded command string with no access to the executing
# shell's alias, function, or variable tables, so no parser at this layer can
# resolve these. Asserted so the behavior is explicit rather than an untested
# assumption.
inp="$(make_input "G=git; ${dollar}G worktree add /tmp/evil")"
check "PERMANENT GAP: variable-obfuscated git is not detected" 0 "${inp}"
inp="$(make_input 'wt worktree add /tmp/evil')"
check "PERMANENT GAP: alias/function resolving to git is not detected" 0 "${inp}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
