#!/usr/bin/env bats
# Tests for ~/.claude/scripts/hook-block-personal-github.sh
#
# Agents act on GitHub only as a GitHub App. The dotfiles gh/git wrappers route
# plain `gh` and `git push` through the App; this hook denies the spellings that
# skip those wrappers or carry a personal credential. arich-mac is exempt.
#
# HOOK_PERSONAL_GH_HOST stands in for `hostname -s`, so the result does not
# depend on the machine that runs the tests.
#
# Run: bats ~/.claude/tests/test_hook_block_personal_github.bats

HOOK="${BATS_TEST_DIRNAME:?}/../scripts/hook-block-personal-github.sh"
SCRIPTS="${BATS_TEST_DIRNAME:?}/../scripts"
# A literal dollar sign, so fixtures can sit in double quotes (SC2016).
D='$'

# bats removes BATS_TEST_TMPDIR itself, so no test runs rm.
setup() {
  SANDBOX_HOME="${BATS_TEST_TMPDIR:?}/home"
  export HOME="${SANDBOX_HOME}"
  mkdir -p "${HOME}/.claude"
}

_make_input() {
  jq -nc --arg cmd "$1" '{"tool_name":"Bash","tool_input":{"command":$cmd}}'
}

# _run_hook <command> [host]: host defaults to a personal Mac.
_run_hook() {
  local input
  input="$(_make_input "$1")" || return 1
  run env HOOK_PERSONAL_GH_HOST="${2:-tilsit}" "${HOOK}" <<<"${input}"
}

_blocks() {
  _run_hook "$@"
  if [ "${status}" -ne 2 ]; then
    echo "expected exit 2, got ${status} for: $1" >&2
    echo "${output}" >&2
    return 1
  fi
  [[ "${output}" == *"GitHub App"* ]]
}

_allows() {
  _run_hook "$@"
  if [ "${status}" -ne 0 ]; then
    echo "expected exit 0, got ${status} for: $1" >&2
    echo "${output}" >&2
    return 1
  fi
}

# ── gh that skips the wrapper ──────────────────────────────────────────────

@test "blocks: command gh" { _blocks 'command gh pr view 1'; }
@test "blocks: command -p gh" { _blocks 'command -p gh api user'; }
@test "blocks: builtin gh" { _blocks 'builtin gh pr list'; }
@test "blocks: exec gh" { _blocks 'exec gh api user'; }
@test "blocks: env gh" { _blocks 'env gh api user'; }
@test "blocks: env -u GH_TOKEN gh" { _blocks 'env -u GH_TOKEN gh pr list'; }
@test "blocks: xargs gh after a pipe" { _blocks 'echo 1 | xargs gh pr view'; }
@test "blocks: absolute path to gh" { _blocks '/opt/homebrew/bin/gh pr view 12 -R smartwatermelon/x'; }
@test "blocks: relative path to gh" { _blocks './bin/gh pr list'; }
@test "blocks: quoted absolute path to gh" { _blocks '"/usr/local/bin/gh" api user'; }
@test "blocks: path to gh chained after &&" { _blocks 'cd /x && /opt/homebrew/bin/gh api user'; }
@test "blocks: path to gh in command substitution" { _blocks "echo \"${D}(/opt/homebrew/bin/gh api user)\""; }
@test "blocks: path to gh with no arguments" { _blocks '/opt/homebrew/bin/gh'; }
@test "blocks: path to gh on a continuation line" { _blocks $'echo start\n/opt/homebrew/bin/gh api user'; }

# ── git push that skips the wrapper ────────────────────────────────────────

@test "blocks: command git push" { _blocks 'command git push origin br'; }
@test "blocks: command git -C push" { _blocks 'command git -C /p push origin br'; }
@test "blocks: absolute path to git, push" { _blocks '/usr/bin/git push origin br'; }
@test "blocks: env git push" { _blocks 'env git push'; }
@test "blocks: exec path to git -C push" { _blocks 'exec /opt/homebrew/bin/git -C /p push'; }
@test "blocks: path to git push after ;" { _blocks 'true; /usr/bin/git push origin br'; }

# ── personal tokens ────────────────────────────────────────────────────────

@test "blocks: GH_TOKEN= assignment before gh" { _blocks 'GH_TOKEN=x gh pr view 1'; }
@test "blocks: empty GH_TOKEN= assignment" { _blocks 'GH_TOKEN= gh pr list'; }
@test "blocks: GITHUB_TOKEN= assignment" { _blocks 'GITHUB_TOKEN=x gh api user'; }
@test "blocks: GH_ENTERPRISE_TOKEN= assignment" { _blocks 'GH_ENTERPRISE_TOKEN=x gh api user'; }
@test "blocks: GH_TOKEN_NOS= after another assignment" { _blocks 'FOO=1 GH_TOKEN_NOS=x gh api user'; }
@test "blocks: export GH_TOKEN=" { _blocks 'export GH_TOKEN=x'; }
@test "blocks: env GH_TOKEN_TWM= cmd" { _blocks 'env GH_TOKEN_TWM=x some-tool'; }
@test "blocks: GH_TOKEN= after &&" { _blocks 'cd /x && GH_TOKEN=x gh api user'; }
@test "blocks: \$GH_TOKEN passed to a tool" { _blocks "some-tool --token ${D}GH_TOKEN"; }
@test "blocks: \"\$GH_TOKEN\" in double quotes" { _blocks "some-tool --token \"${D}GH_TOKEN\""; }
@test "blocks: \${GH_TOKEN_NOS} expansion" { _blocks "echo \"${D}{GH_TOKEN_NOS}\""; }
@test "blocks: \${GH_TOKEN:-} expansion" { _blocks "[[ -n \"${D}{GH_TOKEN:-}\" ]]"; }
@test "blocks: \$GITHUB_TOKEN expansion" { _blocks "printf '%s' \"${D}GITHUB_TOKEN\" | wc -c"; }

# ── HTTP clients with a credential ─────────────────────────────────────────

@test "blocks: curl with Authorization to api.github.com" { _blocks 'curl -H "Authorization: token abc" https://api.github.com/user'; }
@test "blocks: curl Bearer \$GH_TOKEN to api.github.com" { _blocks "curl -sS -H \"Authorization: Bearer ${D}GH_TOKEN\" https://api.github.com/user"; }
@test "blocks: curl -u to api.github.com" { _blocks 'curl -u user:abc https://api.github.com/user'; }
@test "blocks: curl --oauth2-bearer to github.com" { _blocks 'curl --oauth2-bearer abc https://github.com/o/r'; }
@test "blocks: curl upload to uploads.github.com" { _blocks 'curl -H "Authorization: token abc" -T f https://uploads.github.com/repos/o/r/releases/1/assets'; }
@test "blocks: curl with header from file" { _blocks 'curl -H @hdrs https://api.github.com/user'; }
@test "blocks: absolute path to curl" { _blocks '/usr/bin/curl -H "Authorization: token abc" https://api.github.com/user'; }
@test "blocks: wget --header Authorization" { _blocks 'wget --header="Authorization: token abc" https://api.github.com/user'; }
@test "blocks: httpie http with Authorization item" { _blocks 'http https://api.github.com/user "Authorization:Bearer abc"'; }
@test "blocks: xh -a" { _blocks 'xh -A bearer -a abc https://api.github.com/user'; }
@test "blocks: curl after a pipe" { _blocks 'echo x | curl -H "Authorization: token abc" -d @- https://api.github.com/graphql'; }

# ── git push with a credential or URL override ─────────────────────────────

@test "blocks: git push git@github.com: URL" { _blocks 'git push git@github.com:o/r.git HEAD:main'; }
@test "blocks: git push ssh://git@github.com URL" { _blocks 'git push ssh://git@github.com/o/r.git br'; }
@test "blocks: git push https token URL" { _blocks 'git push https://x-access-token:abc@github.com/o/r.git br'; }
@test "blocks: git -C push https token URL" { _blocks 'git -C /p push https://abc@github.com/o/r.git br'; }
@test "blocks: git push plain https github URL" { _blocks 'git push https://github.com/o/r.git br'; }
@test "blocks: git -c credential.helper= push" { _blocks 'git -c credential.helper=store push origin br'; }
@test "blocks: git -c core.sshCommand= push (quoted)" { _blocks 'git -c core.sshCommand="ssh -i k" push origin br'; }
@test "blocks: git -c http.extraheader push" { _blocks 'git -c http.extraheader="AUTHORIZATION: basic abc" push origin br'; }
@test "blocks: GIT_SSH_COMMAND= git push" { _blocks 'GIT_SSH_COMMAND="ssh -i k" git push origin br'; }
@test "blocks: git push URL after &&" { _blocks 'cd /p && git push git@github.com:o/r.git br'; }

# ── known-good ─────────────────────────────────────────────────────────────

@test "allows: gh pr view -R" { _allows 'gh pr view 12 -R smartwatermelon/x'; }
@test "allows: git -C push origin" { _allows 'git -C /p push origin br'; }
@test "allows: git push origin" { _allows 'git push origin br'; }
@test "allows: gh api repos/o/r" { _allows 'gh api repos/o/r'; }
@test "allows: echo with gh and token words" { _allows 'echo "use gh to read the token"'; }
@test "allows: commit message file path with gh and token" { _allows 'git -C /p commit -F /scratch/gh-token-notes.txt'; }
@test "allows: commit message naming a blocked spelling" { _allows 'git commit -m "explain why command gh is blocked"'; }
@test "allows: cat a path under a gh directory" { _allows 'cat /Users/x/.config/gh/token-notes.txt'; }
@test "allows: ls the gh binary" { _allows 'ls -l /opt/homebrew/bin/gh'; }
@test "allows: command -v gh" { _allows 'command -v gh'; }
@test "allows: type gh" { _allows 'type gh'; }
@test "allows: command git status" { _allows 'command git status'; }
@test "allows: unset GH_TOKEN" { _allows 'unset GH_TOKEN'; }
@test "allows: unauthenticated curl to api.github.com" { _allows 'curl -sS https://api.github.com/zen'; }
@test "allows: curl with Authorization to another host" { _allows 'curl -H "Authorization: Bearer abc" https://api.example.com/v1'; }
@test "allows: git fetch over SSH (not covered)" { _allows 'git fetch git@github.com:o/r.git main'; }
@test "allows: git clone over SSH (not covered)" { _allows 'git clone git@github.com:o/r.git /p'; }
@test "allows: gh-something tool" { _allows '/usr/local/bin/gh-dash --help'; }

# ── arich-mac exemption ────────────────────────────────────────────────────

@test "exempt: ARICH-MAC passes a path to gh" {
  _allows '/opt/homebrew/bin/gh pr view 1' ARICH-MAC
}

@test "exempt: arich-mac passes GH_TOKEN= and a git@ push" {
  _allows 'GH_TOKEN=x gh pr view 1' arich-mac
  _allows 'git push git@github.com:o/r.git br' arich-mac
  _allows 'curl -H "Authorization: token abc" https://api.github.com/user' arich-mac
}

@test "not exempt: a host that only contains arich-mac" {
  _blocks 'command gh pr view 1' arich-mac2
}

# ── logging ────────────────────────────────────────────────────────────────

@test "log: names the rule, not the command text" {
  _blocks 'GH_TOKEN=secretvalue gh pr view 1'
  run cat "${HOME}/.claude/blocked-commands.log"
  [[ "${output}" == *"BLOCKED PERSONAL GITHUB"* ]]
  [[ "${output}" != *"secretvalue"* ]]
}

@test "log: an unwritable log still blocks with exit 2" {
  export HOME="${BATS_TEST_TMPDIR:?}/no-claude-dir"
  mkdir -p "${HOME}"
  _blocks 'command gh pr view 1'
}

# ── dispatcher ─────────────────────────────────────────────────────────────

_run_dispatcher() {
  local hookdir="${SANDBOX_HOME}/scripts"
  mkdir -p "${hookdir}"
  cp -Rp "${SCRIPTS}/." "${hookdir}/"
  local input
  input="$(_make_input "$1")" || return 1
  run env HOOK_PERSONAL_GH_HOST=tilsit "${hookdir}/hook-block-all.sh" <<<"${input}"
}

@test "dispatcher: hook-block-all.sh runs this hook" {
  _run_dispatcher 'command gh pr view 1'
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"GitHub App"* ]]
}

@test "dispatcher: gh auth token/login/switch/refresh stay blocked (hook-block-gh-auth.sh)" {
  local a="gh ""auth"
  for verb in token login switch refresh; do
    _run_dispatcher "${a} ${verb}"
    [ "${status}" -eq 2 ]
  done
}

@test "dispatcher: known-good gh and git pass" {
  _run_dispatcher 'gh pr view 12 -R smartwatermelon/x'
  [ "${status}" -eq 0 ]
  _run_dispatcher 'git -C /p push origin br'
  [ "${status}" -eq 0 ]
}
