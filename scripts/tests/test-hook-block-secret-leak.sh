#!/usr/bin/env bash
# Tests for hook-block-secret-leak.sh
#
# The hook compares against the LIVE environment, so these tests inject their
# own fake secrets and run the hook as a child with that environment. No real
# credential is ever placed in a test.

set -uo pipefail

# `cd` with a RELATIVE argument searches CDPATH before the current directory,
# and prints the resolved path to stdout when it matches there. With
# `CDPATH=/Users/andrewrich/Developer`, `cd "$(dirname ...)/.."` lands in
# `Developer/scripts` instead of `claude-config/scripts` AND emits that path,
# so the command substitution captures `pwd` doubled and newline-joined. HOOK
# then points at a file that does not exist and every check exits 127.
#
# The failure is invocation-dependent -- 50/50 green when run directly, 49
# failures when the environment carries CDPATH -- which is the false-green
# shape this codebase has been bitten by before. The production dispatcher
# (hook-block-all.sh) already unsets CDPATH; the tests did not.
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${SCRIPT_DIR}/hook-block-secret-leak.sh"

pass=0
fail=0

# A fake secret long enough to clear MIN_SECRET_LEN, shaped like a real PAT but
# not one. Its literal value is what prong 1 must match.
FAKE_TOKEN="ghp_TESTFAKE0000000000000000000000000000"
FAKE_OP="ops_TESTFAKE1111111111111111111111111111"

make_input() {
  jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

# check <description> <expected_exit> <command-text>
check() {
  local desc="$1" want="$2" cmdtext="$3"
  local got
  make_input "${cmdtext}" \
    | env GH_TOKEN="${FAKE_TOKEN}" OP_SERVICE_ACCOUNT_TOKEN="${FAKE_OP}" \
      bash "${HOOK}" >/dev/null 2>&1
  got=$?
  if [[ "${got}" -eq "${want}" ]]; then
    printf 'PASS: %s\n' "${desc}"
    pass=$((pass + 1))
  else
    printf 'FAIL: %s (want exit %s, got %s)\n' "${desc}" "${want}" "${got}"
    fail=$((fail + 1))
  fi
}

echo "=== BLOCK: the two real-world leak shapes ==="

# Fixtures must reach the hook as LITERAL text -- if the test shell expanded
# them, the hook would receive an already-substituted string and every test
# would be meaningless. `D` holds a dollar sign so the fixtures can be written
# in double quotes (satisfying SC2016) while staying unexpanded.
D='$'

# The exact command that leaked GH_TOKEN on 2026-09-09.
check "the actual 2026-09-09 leak: ${D}{VAR:-fallback}" 2 \
  "echo \"GH_TOKEN set? ${D}{GH_TOKEN:+YES}${D}{GH_TOKEN:-NO}\""
check "${D}{VAR-fallback} (no colon)" 2 "echo \"${D}{GH_TOKEN-none}\""
check "${D}{VAR:=default}" 2 "echo \"${D}{GH_TOKEN:=x}\""
check "${D}{VAR:?message}" 2 "echo \"${D}{GH_TOKEN:?unset}\""
check 'literal secret value in command text' 2 \
  "curl -H \"Authorization: Bearer ${FAKE_TOKEN}\" https://api.github.com"
check "bare ${D}VAR in echo" 2 "echo ${D}GH_TOKEN"
check "bare ${D}{VAR} in printf" 2 "printf \"%s\" ${D}{GH_TOKEN}"
check 'a non-GH secret is caught too' 2 "echo \"${D}{OP_SERVICE_ACCOUNT_TOKEN:-no}\""

echo
echo "=== BLOCK: environment dumps ==="
check 'bare env' 2 'env'
check 'printenv' 2 'printenv'
check 'export -p' 2 'export -p'
check 'env piped to grep (values survive)' 2 'env | grep TOKEN'

echo
echo "=== ALLOW: the safe idioms the error message recommends ==="
# If these ever block, the hook has made itself unusable and the model will
# have no correct way to check whether a variable is set.
check "${D}{VAR:+SET} marker" 0 "echo \"${D}{GH_TOKEN:+SET}\""
check "${D}{#VAR} length" 0 "echo \"${D}{#GH_TOKEN}\""
check "[[ -n \"${D}VAR\" ]] test" 0 "if [[ -n \"${D}GH_TOKEN\" ]]; then echo yes; fi"
check 'env piped to cut -d= -f1 (names only)' 0 'env | cut -d= -f1'
check "env piped to awk print ${D}1 (names only)" 0 "env | awk -F= '{print ${D}1}'"
check 'compgen -v' 0 'compgen -v'

echo
echo "=== BLOCK: partial-value expansions ==="
# Every operator except `:+` / `+` reveals some of the value. `${VAR:0:4}` is
# the natural "just show me the prefix" move and must not be a loophole.
check "${D}{VAR:0:4} first four chars" 2 "echo \"${D}{GH_TOKEN:0:4}\""
check "${D}{VAR:1} all but the first" 2 "echo \"${D}{GH_TOKEN:1}\""
check "${D}{VAR#prefix} strip prefix" 2 "echo \"${D}{GH_TOKEN#ghp_}\""
check "${D}{VAR%suffix} strip suffix" 2 "echo \"${D}{GH_TOKEN%xyz}\""
check "${D}{VAR/a/b} search-replace" 2 "echo \"${D}{GH_TOKEN/ghp_/X}\""

echo
echo "=== BLOCK: printing one named variable ==="
# These take the NAME with no dollar sign, so the expansion patterns never
# see them.
check 'printenv NAME' 2 'printenv GH_TOKEN'
check 'declare -p NAME' 2 'declare -p GH_TOKEN'
check 'bare set (dumps vars and functions)' 2 'set'

echo
echo "=== ALLOW: ordinary commands ==="
check 'plain git status' 0 'git status'
check 'a command merely mentioning the word token' 0 'grep -rn token ./src'
check 'unrelated variable expansion' 0 "echo \"${D}{HOME}\""
check 'gh command that uses the token implicitly' 0 'gh pr list --limit 5'
check 'empty command' 0 ''

# PATH is >=16 chars and contains "PAT". If the name hints ever match it as a
# substring again, this blocks -- and a hook that blocks `echo "$PATH"` gets
# switched off within the hour.
check "echo ${D}PATH is not a secret" 0 "echo \"${D}PATH\""
check "echo ${D}PYTHONPATH" 0 "echo \"${D}PYTHONPATH\""
check 'KEYBOARD-style name is not a secret' 0 "echo \"${D}KEYBOARD_LAYOUT_NAME\""

# Allowed: prints no secret. The gh wrapper closes its keyring path (claude-wrapper#124).
check 'env -u GH_TOKEN gh pr list (the workaround)' 0 'env -u GH_TOKEN gh pr list'
check 'set with arguments is not a dump' 0 'set -euo pipefail'
check 'set +x is not a dump' 0 'set +x'

# `set` and `env` appearing mid-command, not as the command.
check 'the word env inside a path' 0 'ls ~/Developer/dev-env'

echo
echo "=== multi-line commands: a printer must not reach across lines ==="
# The false positive that made per-owner token surveys impossible: an `echo`
# heading on one line made EVERY later secret expansion block, even though the
# two are separate commands and the later one prints nothing.
#
# The discriminating pair is the whole point -- identical token usage, differing
# only in whether an unrelated `echo` precedes it. Before the fix the first
# blocked and the second allowed.
check 'echo heading, then a token-prefixed gh call (separate lines)' 0 \
  "echo \"=== survey ===\"
GH_TOKEN=\"${D}GH_TOKEN\" gh api repos/x/y"
check 'the same token-prefixed call with no echo (control for the pair)' 0 \
  "GH_TOKEN=\"${D}GH_TOKEN\" gh api repos/x/y"

# The for-loop shape from the original report. The loop is incidental -- it
# blocked because `echo` preceded it, not because of the loop.
check 'token-prefixed call inside a for loop after an echo' 0 \
  "echo start
for r in a b; do GH_TOKEN=\"${D}GH_TOKEN\" gh api \"repos/x/\${r}\"; done"

# A backslash-newline is a CONTINUATION, not a separator: this is one logical
# command that really does print the token. Scoping the gap to a single line
# must not lose it.
check 'backslash-continuation still reaches the secret (real leak)' 2 \
  "echo \\
\"${D}GH_TOKEN\""

# An unquoted heredoc delimiter leaves the body subject to expansion. Before
# the gap fix this was caught only because the gap spanned newlines; it now has
# its own rule, because it is a genuine leak.
check 'unquoted heredoc expands the secret into output' 2 \
  "cat <<EOF
${D}GH_TOKEN
EOF"
check 'quoted heredoc delimiter disables expansion' 0 \
  "cat <<'EOF' > /tmp/p.sh
export GH_TOKEN=\"${D}GH_TOKEN_NOS\"
EOF"

# The heredoc rule reads only the body (#536): a secret used outside an
# unrelated unquoted heredoc is not expanded by it.
check 'secret used before an unrelated unquoted heredoc' 0 \
  "GH_TOKEN=\"${D}GH_TOKEN\" gh api user
cat <<EOF
hello
EOF"
check 'secret used after the heredoc terminator' 0 \
  "cat <<EOF > /tmp/n.txt
hello
EOF
GH_TOKEN=\"${D}GH_TOKEN\" gh api user"
check 'secret in a <<- body with a tab-indented terminator' 2 \
  "cat <<-EOF
	${D}{GH_TOKEN}
	EOF"
check 'a tab-indented line does not end a plain <<EOF body' 2 \
  "cat <<EOF
	EOF
${D}GH_TOKEN
EOF"
check 'secret in an unterminated heredoc body' 2 \
  "cat <<EOF
${D}GH_TOKEN"

echo
echo "=== ALLOW: fixtures must not false-positive ==="
# This is the failure mode of a token-pattern regex. These fake tokens are not
# in the environment, so exact-value matching cannot match them.
check 'a fake token in a test fixture' 0 \
  "assert_eq \"${D}(auth)\" \"ghp_FAKE000000000000000000000000000000\""
check 'a token-shaped string in a comment' 0 \
  'echo "# example: ghp_abcdefghijklmnopqrstuvwxyz0123456789"'

echo
echo "=== PINNED DECISION: \${VAR:-} blocks even without a printer ==="
# `[[ -n "${GH_TOKEN:-}" ]]` cannot actually print anything, and blocking a
# grep for the literal string ':-' is over-broad. Both are blocked anyway:
# _DANGEROUS_BRACE does not require a printing context.
#
# This is deliberate, and the conservative side of the tradeoff. The `:-`
# form is what leaked the token twice; `${VAR:+}` is a correct, equally short
# substitute for the set-check, and the block message names it. Recorded as a
# test so a future change to this behavior is a decision, not a regression.
check "safe-looking [[ -n \"${D}{VAR:-}\" ]] still blocks (by design)" 2 \
  "if [[ -n \"${D}{GH_TOKEN:-}\" ]]; then echo yes; fi"

# Searching for the literal text is NOT blocked: the pattern requires a real
# `${` expansion, so grepping the codebase for this idiom still works. That
# matters -- auditing for the dangerous form must not itself be forbidden.
check "grep for the literal string is allowed" 0 \
  "grep -rn 'GH_TOKEN:-' ."

echo
echo "=== BLOCK: 1Password commands that print whole items (#731) ==="
# The first command leaked a whole item on 2026-10-15. JSON output shows
# concealed values with no --reveal.
check 'the actual 2026-10-15 leak: op item get --format json' 2 \
  'op item get "Cloudflare NOS" --vault Automation --format json'
check 'op item get --format=json' 2 \
  'op item get "Cloudflare NOS" --vault Automation --format=json'
check 'op item get --format JSON (case)' 2 'op item get X --format JSON'
check 'op item get --reveal' 2 'op item get X --reveal'
check 'op item get --fields' 2 'op item get X --fields label=credential'
check 'op item get --fields=' 2 'op item get X --fields=credential'
check 'op item get --otp' 2 'op item get X --otp'
check 'op global flag before the subcommand' 2 \
  'op --account my.1password.com item get X --format json'
check 'OP_FORMAT=json prefix' 2 'OP_FORMAT=json op item get X'
check 'timeout wrapper' 2 'timeout 10 op item get X --format json'
check 'env wrapper' 2 'env -u FOO op item get X --format=json'
check 'command wrapper' 2 'command op item get X --format json'
check 'absolute path to op' 2 '/opt/homebrew/bin/op item get X --format json'
check 'piped into jq' 2 'op item get X --format json | jq .fields'
check 'redirected to a file' 2 'op item get X --format json > /tmp/x.json'
check 'inside a capture' 2 "v=\"${D}(op item get X --format json)\""
check 'inside bash -c' 2 "bash -c 'op item get X --format json'"
check 'after another command' 2 'cd /tmp && op item get X --reveal'
check 'on a later line' 2 "echo start
op item get X --format json"
check 'via xargs' 2 'echo X | xargs op item get --format json'
check 'op document get without --out-file' 2 'op document get "Some Doc"'
check 'op document get with --vault but no --out-file' 2 \
  'op document get Doc --vault Automation'
check 'op item list --format json piped into op item get' 2 \
  'op item list --vault Automation --format json | op item get -'
check 'op item list --format=json piped into op item get' 2 \
  'op item list --format=json | op item get - --vault Automation'
check 'export OP_FORMAT=json earlier in the command' 2 \
  'export OP_FORMAT=json; op item get X'
check 'bash -lc (combined flag cluster)' 2 "bash -lc 'op item get X --reveal'"

# An unbalanced quote makes the parser give up; the regex fallback runs.
check 'fallback: unparsable op item get --format json' 2 \
  'op item get "Cloudflare NOS" --format json "'
check 'fallback: unparsable list piped into get' 2 \
  'op item list --format json | op item get - "'
check 'fallback: unparsable op document get' 2 'op document get "Doc'

echo
echo "=== ALLOW: 1Password forms that print no field values ==="
# `op read` is the interface the deny message recommends. If it blocks, the
# hook leaves no correct way to fetch a secret.
check 'op read (the recommended path)' 0 'op read "op://Automation/Item/field"'
check 'op read captured' 0 "k=\"${D}(op read op://v/i/f)\""
check 'op item get with no format (metadata, values concealed)' 0 \
  'op item get "Cloudflare NOS" --vault Automation'
check 'op item get --format human-readable' 0 \
  'op item get X --format human-readable'
check 'plain op item list' 0 'op item list --vault Automation'
check 'op item list --format json alone' 0 'op item list --format json'
check 'op item list --format json into jq (titles only)' 0 \
  'op item list --format json | jq -r ".[].title"'
check 'op document get --out-file' 0 'op document get Doc --out-file /tmp/f'
check 'op document get -o' 0 'op document get Doc -o /tmp/f'
check 'op vault list' 0 'op vault list'
check 'OP_FORMAT=human-readable op item get' 0 \
  'OP_FORMAT=human-readable op item get X'
check 'fallback: unparsable op read' 0 'op read "op://v/i/f'
check 'grep for the phrase op item get' 0 "grep -rn 'op item get' notes.md"
check 'echo naming the command' 0 'echo "never run op item get --format json"'

# Bare env: the env prongs skip when no secret var is set, and the op check
# must still fire.
make_input 'op item get "Cloudflare NOS" --vault Automation --format json' \
  | env -i PATH="${PATH}" HOME="${HOME}" bash "${HOOK}" >/dev/null 2>&1
bare_rc=$?
if [[ "${bare_rc}" -eq 2 ]]; then
  printf 'PASS: op item get --format json blocks with no secrets in the env\n'
  pass=$((pass + 1))
else
  printf 'FAIL: op item get --format json with bare env (want 2, got %s)\n' \
    "${bare_rc}"
  fail=$((fail + 1))
fi

# The deny message must name the interface to use instead.
op_msg=$(make_input 'op item get X --format json' \
  | env -i PATH="${PATH}" HOME="${HOME}" bash "${HOOK}" 2>&1 >/dev/null)
if printf '%s' "${op_msg}" | grep -qF 'op read op://'; then
  printf 'PASS: the op deny message points to op read op://\n'
  pass=$((pass + 1))
else
  printf 'FAIL: the op deny message does not name op read op://\n'
  fail=$((fail + 1))
fi

echo
echo "=== control: the detector must actually be running ==="
# If the detector silently no-ops, every test above passes for the wrong
# reason. This asserts a known-bad input really does block.
control_out=$(make_input "echo \"${D}{GH_TOKEN:-LEAK}\"" \
  | env GH_TOKEN="${FAKE_TOKEN}" bash "${HOOK}" 2>&1 >/dev/null)
control_rc=$?
if [[ "${control_rc}" -eq 2 ]] && printf '%s' "${control_out}" | grep -q 'GH_TOKEN'; then
  printf 'PASS: control -- known-bad input blocks and names the variable\n'
  pass=$((pass + 1))
else
  printf 'FAIL: control -- known-bad input did not block (rc=%s)\n' "${control_rc}"
  fail=$((fail + 1))
fi

# The block message must never contain the secret itself.
if printf '%s' "${control_out}" | grep -qF "${FAKE_TOKEN}"; then
  printf 'FAIL: the block message leaked the secret value\n'
  fail=$((fail + 1))
else
  printf 'PASS: the block message does not contain the secret value\n'
  pass=$((pass + 1))
fi

echo
echo "======================================="
printf 'Results: %d passed, %d failed\n' "${pass}" "${fail}"
echo "======================================="
[[ "${fail}" -eq 0 ]]
