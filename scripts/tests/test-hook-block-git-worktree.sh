#!/usr/bin/env bash
# Tests for hook-block-git-worktree.sh
#
# `add` always exits 0 (2026-10-27): matcher cases probe with `move`.

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

# check_audit <desc> <yes|no> <input> [verb]
# Asserts exit 0 AND whether an audit line for <verb> was written.
check_audit() {
  local desc="${1}" expect_logged="${2}" input="${3}" verb="${4:-remove}"
  local tmphome logfile actual=0 logged=no
  tmphome="$(mktemp -d)"
  mkdir -p "${tmphome}/.claude"
  logfile="${tmphome}/.claude/blocked-commands.log"
  printf '%s\n' "${input}" | HOME="${tmphome}" "${HOOK}" >/dev/null 2>&1 || actual=$?
  # One anchored pattern: the whole record must sit on one line.
  if [[ -s "${logfile}" ]] && grep -qE \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z AUDIT GIT WORKTREE ${verb^^} \(out of scope: [^)]+\): .*worktree ${verb}" \
    "${logfile}"; then
    logged=yes
  fi
  if [[ "${actual}" -eq 0 && "${logged}" == "${expect_logged}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (exit ${actual} want 0; logged=${logged} want ${expect_logged})"
    ((fail += 1))
  fi
}

# Fragments, so the hook sees UNEXPANDED references.
dollar='$'
backtick='`'
sq="'"
dq='"'

echo "=== hook-block-git-worktree tests ==="

# Should BLOCK (exit 2) — administrative subcommands, bare worktree, unknown
# subcommands
inp="$(make_input 'git worktree move /tmp/wt /tmp/wt2')"
check "git worktree move" 2 "${inp}"
inp="$(make_input 'git worktree lock /tmp/wt')"
check "git worktree lock" 2 "${inp}"
inp="$(make_input 'git worktree repair')"
check "git worktree repair" 2 "${inp}"
inp="$(make_input 'git worktree')"
check "bare git worktree (no subcommand)" 2 "${inp}"
inp="$(make_input 'git worktree unknownfuturesubcommand')"
check "git worktree unknown subcommand (fail closed)" 2 "${inp}"
inp="$(make_input 'git -C /some/path worktree move /tmp/a /tmp/b')"
check "git -C /path, move" 2 "${inp}"
inp="$(make_input 'git --no-pager worktree lock /tmp/wt')"
check "git --no-pager, lock" 2 "${inp}"
inp="$(make_input 'cd /repo && git worktree move /tmp/a /tmp/b')"
check "chained: cd && move" 2 "${inp}"

# --- dotfiles#200: cleanup subcommands are ALLOWED ---
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
inp="$(make_input 'git worktree remove --force .claude/worktrees/agent-abc')"
check "cleanup: remove --force (required for dirty worktrees)" 0 "${inp}"
# unlock is allowed (2026-10-21): `remove -f -f` already deletes a locked
# worktree. `lock` stays blocked.
inp="$(make_input 'git worktree unlock .claude/worktrees/agent-abc')"
check "cleanup: unlock (now allowed)" 0 "${inp}"
inp="$(make_input 'git worktree remove -f -f .claude/worktrees/agent-abc')"
check "cleanup: remove -f -f of a locked worktree (allowed)" 0 "${inp}"
inp="$(make_input 'git worktree prune --dry-run')"
check "cleanup: prune --dry-run" 0 "${inp}"
# ACCEPTED TRADE-OFF (#347): cleanup is NOT path-scoped. See the hook header
# before changing this.
inp="$(make_input 'git worktree remove --force /tmp/other-agents-worktree')"
check "cleanup: forceful out-of-scope remove (deliberately allowed, #347)" 0 "${inp}"

# --- Creation: ALWAYS allowed; in-scope creation is NOT audited ---
inp="$(make_input 'git worktree add .claude/worktrees/agent-abc123')"
check_audit "creation: scoped relative path, not audited" no "${inp}" add
inp="$(make_input 'git worktree add ./.claude/worktrees/agent-abc123')"
check_audit "creation: scoped ./ relative path, not audited" no "${inp}" add
inp="$(make_input 'git worktree add /Users/me/Developer/repo/.claude/worktrees/wt1')"
check_audit "creation: scoped absolute path, not audited" no "${inp}" add
inp="$(make_input 'git worktree add -b claude/my-feature .claude/worktrees/wt1')"
check_audit "creation: scoped with -b branch before path, not audited" no "${inp}" add
inp="$(make_input 'git worktree add --no-track -b claude/fix-x-1 .claude/worktrees/wt1 origin/main')"
check_audit "creation: the documented raw command, not audited" no "${inp}" add
inp="$(make_input 'git worktree add --detach .claude/worktrees/wt1')"
check_audit "creation: scoped with valueless flag, not audited" no "${inp}" add
inp="$(make_input 'git worktree add .claude/worktrees/wt1 HEAD~2')"
check_audit "creation: scoped with trailing commit-ish, not audited" no "${inp}" add
inp="$(make_input 'git -C /some/repo worktree add .claude/worktrees/wt1')"
check_audit "creation: scoped with interposed -C flag, not audited" no "${inp}" add

# --- Creation not PROVABLY in scope: allowed (exit 0) AND audited ---
#
# `$W/...` is the false positive that made `add` audit-only.
inp="$(make_input "git worktree add ${dollar}W/.claude/worktrees/x")"
check_audit "creation: \$W/.claude/worktrees/x is allowed and audited" yes "${inp}" add
inp="$(make_input "git -C ${dollar}REPO worktree add --no-track -b claude/a-b-c ${dollar}W/.claude/worktrees/x origin/main")"
check_audit "creation: variable path with flags is allowed and audited" yes "${inp}" add
inp="$(make_input 'git worktree add /tmp/wt feature')"
check_audit "creation: outside scope (/tmp) is allowed and audited" yes "${inp}" add
inp="$(make_input 'git -C /some/path worktree add /tmp/wt')"
check_audit "creation: -C /path, outside scope, audited" yes "${inp}" add
inp="$(make_input 'cd /repo && git worktree add /tmp/wt')"
check_audit "creation: chained cd && outside scope, audited" yes "${inp}" add
inp="$(make_input 'git worktree add ../elsewhere/.claude/worktrees/wt1')"
check_audit "creation: leading .. traversal is audited" yes "${inp}" add
inp="$(make_input 'git worktree add .claude/worktrees/../../escape')"
check_audit "creation: embedded .. traversal is audited" yes "${inp}" add
inp="$(make_input "git worktree add ${dollar}HOME/.claude/worktrees/wt1")"
check_audit "creation: unexpanded \$HOME is audited" yes "${inp}" add
inp="$(make_input 'git worktree add ~/.claude/worktrees/wt1')"
check_audit "creation: unexpanded ~ is audited" yes "${inp}" add
inp="$(make_input 'git worktree add .claude/worktrees/*')"
check_audit "creation: glob is audited" yes "${inp}" add
inp="$(make_input 'git worktree add .claude/worktrees')"
check_audit "creation: bare scope dir with no leaf is audited" yes "${inp}" add
inp="$(make_input 'git worktree add')"
check_audit "creation: missing path is audited as <no path>" yes "${inp}" add
inp="$(make_input 'git worktree add -b claude/feature')"
check_audit "creation: -b consuming the only operand is audited" yes "${inp}" add
inp="$(make_input 'git worktree add /tmp/.claude/worktreesevil/wt1')"
check_audit "creation: scope-lookalike prefix is audited" yes "${inp}" add
inp="$(make_input 'git worktree add notclaude/worktrees/wt1')"
check_audit "creation: non-scope path is audited" yes "${inp}" add
inp="$(make_input 'git worktree add .claude/worktrees/ok && git worktree add /tmp/bad')"
check_audit "compound: scoped add && unscoped add is audited" yes "${inp}" add

# A quoted MENTION is not an invocation, so it is not audited.
inp="$(make_input "echo ${dq}git worktree add /tmp/x${dq}")"
check_audit "mention: echo of an add string is not audited" no "${inp}" add
inp="$(make_input "grep -r ${dq}git worktree add${dq} docs/")"
check_audit "mention: grep for the phrase in docs is not audited" no "${inp}" add
inp="$(make_input "echo ${dq}git worktree add /tmp/evil${dq} && grep -r ${dq}git worktree add /tmp/evil${dq} docs/")"
check_audit "repeated literal: two mentions of the same literal are not audited" no "${inp}" add
# A quoted INVOCATION is audited.
inp="$(make_input "bash -c ${sq}git worktree add /tmp/evil${sq}")"
check_audit "invocation: bash -c add outside scope is audited" yes "${inp}" add
inp="$(make_input "echo ${dq}git worktree add /tmp/evil${dq} && bash -c ${dq}git worktree add /tmp/evil${dq}")"
check_audit "repeated literal: executor at the second occurrence is audited" yes "${inp}" add
inp="$(make_input "echo ${backtick}git worktree add /tmp/evil${backtick}")"
check_audit "backtick substitution: add outside scope is audited" yes "${inp}" add

# --- Backslash in a path (read -r -a does not honor the escape) ---
#
# The split token is not provably in scope, so it is audited.
bs="\\\\"
inp="$(make_input "git worktree add .claude/worktrees/my${bs} evil")"
check_audit "backslash: escaped space in an in-scope path is audited" yes "${inp}" add
inp="$(make_input "git worktree add .claude/worktrees/plain")"
check_audit "backslash: an unescaped scoped path is not audited" no "${inp}" add

# Trailing-quote normalization on the path token (#377).
inp="$(make_input "bash -c ${sq}git worktree add .claude/worktrees/ok${sq}")"
check_audit "quoted path: scoped creation via bash -c is not audited" no "${inp}" add
inp="$(make_input "bash -c ${dq}git worktree add .claude/worktrees/ok${dq}")"
check_audit "quoted path: scoped creation via bash -c double-quoted is not audited" no "${inp}" add
inp="$(make_input "git worktree add ${dq}.claude/worktrees/ok${dq}")"
check_audit "quoted path: quoted scoped path is not audited" no "${inp}" add
inp="$(make_input "git worktree add .claude/worktrees/ok${sq}${dq}")"
check_audit "quoted path: trailing quote pair on a scoped path is not audited" no "${inp}" add
inp="$(make_input "git worktree add /tmp/evil${sq}${dq}")"
check_audit "quoted path: trailing quote pair on an unscoped path is audited" yes "${inp}" add

# A creation must not launder a mutating sibling in a compound command.
inp="$(make_input 'git worktree add .claude/worktrees/ok && git worktree move /a /b')"
check "compound: scoped add && move (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree add /tmp/x && git worktree lock /a')"
check "compound: unscoped add && lock (must still block)" 2 "${inp}"
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
inp="$(make_input 'ls; git worktree move /a /b')"
check "chained: ; git worktree move" 2 "${inp}"
inp="$(make_input 'true || git worktree prune')"
check "chained: || git worktree prune (cleanup, now allowed)" 0 "${inp}"
inp="$(make_input 'true || git worktree move /a /b')"
check "chained: || git worktree move (still blocked)" 2 "${inp}"
inp="$(make_input 'echo x | git worktree lock /a')"
check "chained: | git worktree lock" 2 "${inp}"

# False-positive guard: git grep searching for "worktree" string
inp="$(make_input 'git grep worktree')"
check "git grep worktree (not blocked)" 0 "${inp}"

# Multi-invocation compound commands: a read-only occurrence must not mask a
# mutating one elsewhere in the same command string (regression for the
# single-match bypass caught in PR review — see smartwatermelon/claude-config#268).
inp="$(make_input 'git worktree list && git worktree move /a /b')"
check "compound: list && move (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list | git worktree move /a /b')"
check "compound: list | move (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree move /a /b && git worktree list')"
check "compound: move && list, mutating first (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list ; git worktree lock /tmp/wt')"
check "compound: list ; lock (must still block)" 2 "${inp}"
inp="$(make_input 'git worktree list ; git worktree remove /tmp/wt')"
check "compound: list ; remove (cleanup, now allowed)" 0 "${inp}"
inp="$(make_input 'git worktree list && git worktree --help')"
check "compound: list && --help, both read-only (must pass)" 0 "${inp}"

# --- Separator coverage (closed by the dotfiles#200 review) ---
# These forms previously evaded the matcher entirely: an unmatched occurrence
# skips every check. Probed with `move`, which still blocks.
inp="$(make_input 'git worktree list & git worktree move /a /b')"
check "separator: & backgrounding" 2 "${inp}"
inp="$(make_input '(git worktree move /a /b)')"
check "separator: subshell parens" 2 "${inp}"
inp="$(make_input 'git status && (git worktree move /a /b)')"
check "separator: subshell after &&" 2 "${inp}"
inp="$(make_input '{ git worktree move /a /b; }')"
check "separator: brace group" 2 "${inp}"
inp="$(make_input 'if true; then git worktree move /a /b; fi')"
check "separator: then keyword" 2 "${inp}"
inp="$(make_input 'for i in 1; do git worktree move /a /b; done')"
check "separator: do keyword" 2 "${inp}"
inp="$(make_input '(git worktree add /tmp/x)')"
check_audit "separator: subshell add outside scope is audited" yes "${inp}" add

# --- Wrapped / path-prefixed invocation (also closed by the review) ---
inp="$(make_input "echo ${dollar}(git worktree move /a /b)")"
check "wrapper: command substitution" 2 "${inp}"
inp="$(make_input '/usr/bin/git worktree move /a /b')"
check "wrapper: absolute-path git" 2 "${inp}"
inp="$(make_input 'env git worktree move /a /b')"
check "wrapper: env-prefixed git" 2 "${inp}"
inp="$(make_input 'command git worktree move /a /b')"
check "wrapper: command-prefixed git" 2 "${inp}"
inp="$(make_input 'sudo git worktree move /a /b')"
check "wrapper: sudo-prefixed git" 2 "${inp}"
inp="$(make_input '/usr/bin/git worktree add /tmp/x')"
check_audit "wrapper: absolute-path git add outside scope is audited" yes "${inp}" add

# False-positive guards for the wrapper/path-prefix alternatives above: a bare
# word merely ENDING in `git` must not match (the prefix requires a `/`).
inp="$(make_input 'mygit worktree move /a /b')"
check "false positive: mygit is not git" 0 "${inp}"
inp="$(make_input 'echo not-git worktree stuff')"
check "false positive: hyphenated word containing git" 0 "${inp}"

# --- Backtick command substitution ---
# The backtick is a separator alternative, and also terminates the captured
# argument list so the closing backtick is not swallowed into a token.
inp="$(make_input "echo ${backtick}git worktree move /tmp/a /tmp/b${backtick}")"
check "backtick substitution: administrative subcommand blocked" 2 "${inp}"
inp="$(make_input "echo ${backtick}git worktree add .claude/worktrees/ok${backtick}")"
check_audit "backtick substitution: scoped creation is not audited" no "${inp}" add
inp="$(make_input "echo ${backtick}git worktree list${backtick}")"
check "backtick substitution: read-only subcommand allowed" 0 "${inp}"

# --- Quote-prefixed git ---
# `git` placed after an opening quote rather than a separator matched none of
# the alternation. Covers single, double, and ANSI-C quoting, and `eval`.
inp="$(make_input "bash -c ${sq}git worktree move /a /b${sq}")"
check "quote prefix: single-quoted move blocked" 2 "${inp}"
inp="$(make_input "bash -c ${dq}git worktree move /a /b${dq}")"
check "quote prefix: double-quoted move blocked" 2 "${inp}"
inp="$(make_input "bash -c ${dollar}${sq}git worktree move /a /b${sq}")"
check "quote prefix: ANSI-C quoted move blocked" 2 "${inp}"
inp="$(make_input "eval ${sq}git worktree move /a /b${sq}")"
check "quote prefix: eval-wrapped move blocked" 2 "${inp}"
inp="$(make_input "bash -c ${sq}git worktree list${sq}")"
check "quote prefix: read-only subcommand allowed" 0 "${inp}"

# --- Heredocs: already matched, asserted so nobody "fixes" a non-gap ---
# grep -oE matches per line, so a heredoc body's `git` sits at line start and
# the `^` alternative catches it (#349 claimed otherwise).
heredoc_cmd=$(printf 'cat <<EOF\ngit %s move /a /b\nEOF' 'worktree')
inp="$(make_input "${heredoc_cmd}")"
check "heredoc body is matched at line start (not a bypass)" 2 "${inp}"

# --- Quoted MENTION vs quoted INVOCATION (#371) ---
# The discriminator is the command PRECEDING the quote. Only a shell or `eval`
# runs the string.
inp="$(make_input "echo ${dq}git worktree move a b${dq}")"
check "mention: echo of an admin string is not an invocation" 0 "${inp}"
inp="$(make_input "echo ${dq}git worktree list${dq}")"
check "mention: echo of a read-only string is not an invocation" 0 "${inp}"
inp="$(make_input "printf '%s' ${dq}git worktree move a b${dq}")"
check "mention: printf of an admin string is allowed" 0 "${inp}"

# The executor forms must still block -- this is the half that must not regress.
inp="$(make_input "sh -c ${sq}git worktree move /a /b${sq}")"
check "invocation: sh -c still blocks despite the mention carve-out" 2 "${inp}"
inp="$(make_input "eval ${dq}git worktree move /a /b${dq}")"
check "invocation: eval double-quoted still blocks" 2 "${inp}"
inp="$(make_input "sudo bash -c ${dq}git worktree move /a /b${dq}")"
check "invocation: sudo bash -c still blocks" 2 "${inp}"
inp="$(make_input "command bash -c ${dq}git worktree move /a /b${dq}")"
check "invocation: command bash -c still blocks" 2 "${inp}"

# Repeated-literal attribution (#383): each occurrence is judged by the command
# preceding THAT occurrence.
inp="$(make_input "echo ${dq}git worktree move /a /b${dq} && bash -c ${dq}git worktree move /a /b${dq}")"
check "repeated literal: executor at the second occurrence still blocks" 2 "${inp}"
inp="$(make_input "bash -c ${dq}git worktree move /a /b${dq} && echo ${dq}git worktree move /a /b${dq}")"
check "repeated literal: executor at the first occurrence still blocks" 2 "${inp}"
inp="$(make_input "echo ${dq}git worktree move /a /b${dq} && grep -r ${dq}git worktree move /a /b${dq} docs/")"
check "repeated literal: two mentions of the same literal stay allowed" 0 "${inp}"

# KNOWN GAP, pinned as CURRENT behavior: a wrapper whose last non-flag word is
# not itself an executor (`pyenv exec`) is read as a mention and skipped. See
# the KNOWN LIMITATION note above _executes_quoted_string.
inp="$(make_input "pyenv exec ${dq}git worktree move /a /b${dq}")"
check "KNOWN GAP: non-executor wrapper word is read as a mention" 0 "${inp}"

# --- PERMANENTLY OPEN gaps, asserted as CURRENT behavior, not desired ---
# A PreToolUse hook sees the raw, unexpanded command string with no access to
# the executing shell's alias, function, or variable tables.
inp="$(make_input "G=git; ${dollar}G worktree move /a /b")"
check "PERMANENT GAP: variable-obfuscated git is not detected" 0 "${inp}"
inp="$(make_input 'wt worktree move /a /b')"
check "PERMANENT GAP: alias/function resolving to git is not detected" 0 "${inp}"

# --- #374: out-of-scope `remove` is ALLOWED but audited ---
inp="$(make_input 'git worktree remove /tmp/peer-agent-wt')"
check_audit "remove outside scope is allowed AND audited" yes "${inp}"
inp="$(make_input 'git worktree remove --force /tmp/peer-agent-wt')"
check_audit "remove --force outside scope is allowed AND audited" yes "${inp}"
inp="$(make_input 'git worktree remove .claude/worktrees/mine')"
check_audit "remove inside scope is allowed and NOT audited" no "${inp}"
inp="$(make_input 'git worktree unlock /tmp/peer-agent-wt')"
check_audit "unlock outside scope is allowed AND audited" yes "${inp}" unlock
inp="$(make_input 'git worktree unlock .claude/worktrees/mine')"
check_audit "unlock inside scope is allowed and NOT audited" no "${inp}" unlock
inp="$(make_input 'git worktree prune')"
check_audit "prune takes no path, so it is never audited" no "${inp}"
# Fails if `prune` is folded into the `remove` branch.
inp="$(make_input 'git worktree prune --expire 3.days.ago')"
check_audit "prune --expire operand is not mistaken for a worktree path" no "${inp}"

# #398: an unwritable log must NOT block an audited command.
check_unwritable_log_allows() {
  local desc="${1}" input="${2}" tmphome actual=0
  tmphome="$(mktemp -d)" # deliberately WITHOUT .claude/, as on first run
  printf '%s\n' "${input}" | HOME="${tmphome}" "${HOOK}" >/dev/null 2>&1 || actual=$?
  if [[ "${actual}" -eq 0 ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (exit ${actual}, want 0 -- audit failure must not block)"
    ((fail += 1))
  fi
}

inp="$(make_input 'git worktree remove /tmp/peer-agent-wt')"
check_unwritable_log_allows "unwritable audit log still allows the remove" "${inp}"
inp="$(make_input 'git worktree add /tmp/stray-wt')"
check_unwritable_log_allows "unwritable audit log still allows the add" "${inp}"

# --- Quoted values on global options (claude-config#430) ---
# A quoted value with spaces once stopped the matcher.
inp="$(make_input 'git -c "user.name=First Last" worktree move /tmp/a /tmp/b')"
check "double-quoted option value, administrative subcommand" 2 "${inp}"
inp="$(make_input "git -c 'user.name=First Last' worktree move /tmp/a /tmp/b")"
check "single-quoted option value, administrative subcommand" 2 "${inp}"
inp="$(make_input 'git -c "a=1 2" -c "b=3 4" worktree move /a /b')"
check "two quoted option values, administrative subcommand" 2 "${inp}"
inp="$(make_input 'git -c "user.name=First Last" -C /some/repo worktree lock /a')"
check "quoted option value alongside -C, lock" 2 "${inp}"
inp="$(make_input 'git -c "user.name=First Last" worktree add /tmp/evil')"
check_audit "double-quoted option value, unscoped creation is audited" yes "${inp}" add
inp="$(make_input 'git -c "user.name=First Last" worktree add .claude/worktrees/agent-1')"
check_audit "double-quoted option value, in-scope creation is not audited" no "${inp}" add

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
