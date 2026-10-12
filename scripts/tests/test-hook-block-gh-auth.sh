#!/usr/bin/env bash
# hook-block-gh-auth.sh (claude-wrapper#124): blocks typed keyring-reaching gh auth verbs, at command position only.

set -euo pipefail
unset CDPATH

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hook-block-gh-auth.sh"
pass=0
fail=0

# Assembled at runtime so this file's own invocation is not blocked by the
# hook it tests (#405).
readonly A="gh ""auth"

check() {
  local desc="${1}" expected="${2}" cmd="${3}"
  local input actual=0

  input="$(jq --null-input --arg c "${cmd}" '{tool_input: {command: $c}}')" || {
    echo "  FAIL: ${desc} (could not build fixture)"
    ((fail += 1))
    return
  }

  printf '%s\n' "${input}" | HOME="${tmphome}" "${HOOK}" >/dev/null 2>"${errfile}" || actual=$?

  if [[ "${actual}" -eq "${expected}" ]]; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc} (expected exit ${expected}, got ${actual})"
    ((fail += 1))
  fi
}

tmphome="$(mktemp -d)"
mkdir -p "${tmphome}/.claude"
errfile="${tmphome}/err"
trap 'rm -rf "${tmphome}"' EXIT

echo "=== gh auth hook tests ==="

echo "--- must BLOCK: each verb typed by the agent"
check "auth token" 2 "${A} token"
check "auth token --user" 2 "${A} token --hostname github.com --user twistedmelonman"
check "auth switch" 2 "${A} switch --user twistedmelonman"
check "auth login" 2 "${A} login --hostname github.com"
check "auth logout" 2 "${A} logout"
check "auth refresh" 2 "${A} refresh -s admin:org"
check "auth git-credential" 2 "${A} git-credential get"
check "auth status --show-token" 2 "${A} status --show-token"
check "auth status -t" 2 "${A} status -t"
check "auth status -h host -t" 2 "${A} status -h github.com -t"
check "auth status -at (flag cluster)" 2 "${A} status -at"
check "auth setup-git" 2 "${A} setup-git"

echo "--- must BLOCK: other command positions and spellings"
check "chained after &&" 2 "cd /x && ${A} token"
check "after a semicolon" 2 "true; ${A} switch"
check "after a pipe" 2 "echo x | ${A} login --with-token"
check "command substitution" 2 "T=\$(${A} token)"
check "backtick substitution" 2 "echo \`${A} token\`"
check "subshell" 2 "(${A} token)"
check "env -u GH_TOKEN prefix" 2 "env -u GH_TOKEN ${A} token"
check "empty GH_TOKEN assignment" 2 "GH_TOKEN= ${A} token"
check "absolute path to gh" 2 "/opt/homebrew/bin/${A} token"
check "backslash gh" 2 "\\${A} token"
check "quoted gh" 2 "\"gh\" auth token"
check "global flag before auth" 2 "gh -R o/r auth token"
check "line continuation" 2 "${A} \\
  token"
check "second line of a script" 2 "echo start
${A} token"

echo "--- must ALLOW"
check "auth status (read-only)" 0 "${A} status"
check "auth status --hostname" 0 "${A} status --hostname github.com"
check "auth status --active" 0 "${A} status --active"
check "ordinary gh use" 0 "gh pr list --limit 5"
check "my_prs (calls gh auth token internally)" 0 "my_prs --json"
check "the env -u workaround is the wrapper's case" 0 "env -u GH_TOKEN gh pr list"
check "commit message mentioning it" 0 "git commit -m \"block ${A} token in hooks\""
check "echo of the text" 0 "echo \"${A} token is blocked\""
check "grep for the text" 0 "grep -rn '${A} token' scripts/"
check "a token-named subcommand of something else" 0 "gh secret list --app actions"
check "authors is not auth" 0 "gh api repos/o/r/authors"
check "empty command" 0 ""

echo "--- the deny message names the restricted token and the remedy"
check "message fixture" 2 "${A} token"
msg="$(cat "${errfile}")"
if [[ "${msg}" == *"GH_TOKEN_SWM"* && "${msg}" == *"fine-grained PAT"* \
  && "${msg}" == *"fleet-probe-token-scopes.md"* ]]; then
  echo "  PASS: message names the tokens and the PAT remedy"
  ((pass += 1))
else
  echo "  FAIL: message missing token names or remedy: ${msg}"
  ((fail += 1))
fi

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
