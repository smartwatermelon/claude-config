#!/usr/bin/env bats
# scripts/harvest-user-settings.sh (#842). Stubs log only; mv/rm refuse paths outside the test dir.

# Fake secrets are made at run time. Run: bats tests/test_harvest_user_settings.bats

SCRIPT="${BATS_TEST_DIRNAME:?}/../scripts/harvest-user-settings.sh"
BUILD="${BATS_TEST_DIRNAME:?}/../scripts/build-machine-settings.sh"
REPO="smartwatermelon/claude-config"
BRANCH="claude/harvest-settings-testhost"

setup() {
  TEST_ROOT="$(cd "${BATS_TEST_TMPDIR:?}" && pwd -P)"
  FAKE_HOME="${TEST_ROOT}/home"
  SRC="${TEST_ROOT}/src"
  LIVE="${TEST_ROOT}/live.json"
  LOCAL="${TEST_ROOT}/local.json"
  WORK="${FAKE_HOME}/.local/state/claude-config/harvest"
  HOSTFILE="${WORK}/user-settings/hosts/TESTHOST.json"
  STUB_LOG="${TEST_ROOT}/stub.log"
  mkdir -p "${FAKE_HOME}" "${SRC}/hosts" "${TEST_ROOT}/tmp" "${TEST_ROOT}/bin"
  : >"${STUB_LOG}"
  make_guarded_stub mv
  make_guarded_stub rm
  make_stubs
  export MACHINE_SETTINGS_MV_BIN="${TEST_ROOT}/bin/mv"
  export MACHINE_SETTINGS_RM_BIN="${TEST_ROOT}/bin/rm"
  export HARVEST_MV_BIN="${TEST_ROOT}/bin/mv"
  export HARVEST_RM_BIN="${TEST_ROOT}/bin/rm"
  export HARVEST_GIT_BIN="${TEST_ROOT}/bin/git"
  export HARVEST_GH_BIN="${TEST_ROOT}/bin/gh"
  export HARVEST_GITLEAKS_BIN="${TEST_ROOT}/bin/gitleaks"
  export HARVEST_NOTIFY_BIN="${TEST_ROOT}/bin/notify"
  export HARVEST_TOKEN_BIN="${TEST_ROOT}/bin/token"
  export HARVEST_SECURITY_BIN="${TEST_ROOT}/bin/security"
  export MACHINE_SETTINGS_TMPDIR="/var/folders/xx/test/T/"
  export STUB_LOG TEST_ROOT
  # A fake App token, made at run time: it must never reach a log or argv.
  STUB_TOKEN="ghs_$(rand_hex 18)"
  export STUB_TOKEN
  write_base <<'JSON'
{"model": "opus", "theme": "dark", "permissions": {"allow": ["Bash(ls:*)"]}, "enabledPlugins": {"a@m": true}}
JSON
}

# Logs its arguments, refuses any path outside TEST_ROOT, then runs <real> (default: the real command).
make_guarded_stub() {
  local name="$1" real="${2:-}" out="${3:-${TEST_ROOT}/bin/$1}"
  [[ -n "${real}" ]] || real="$(command -v "${name}")"
  {
    cat <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"${STUB_LOG}"
refuse() {
  echo "stub: refusing: $1" >&2
  exit 99
}
for a in "$@"; do
  # Short flags only (-f, -t); a long option could carry a path, so it is refused.
  case "${a}" in
    -[A-Za-z] | -[A-Za-z][A-Za-z]) continue ;;
    -*) refuse "option ${a}" ;;
    */../* | */.. | ../* | ..) refuse "a .. path: ${a}" ;;
    "${TEST_ROOT}"/*) ;;
    *) refuse "a path outside the test dir: ${a}" ;;
  esac
  # A symlinked parent could point outside: check the physical parent too.
  parent="$(cd -P "$(dirname "${a}")" 2>/dev/null && pwd -P)" || refuse "no parent dir for ${a}"
  case "${parent}/" in
    "${TEST_ROOT}"/*) ;;
    *) refuse "a parent outside the test dir: ${a}" ;;
  esac
done
STUB
    printf 'exec %q "$@"\n' "${real}"
  } >"${out}"
  chmod +x "${out}"
}

make_stubs() {
  # git: logs argv and the global-config env. clone makes the work tree.
  cat >"${TEST_ROOT}/bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >>"${TEST_ROOT}/git.log"
printf 'env GIT_CONFIG_GLOBAL=%s GIT_CONFIG_NOSYSTEM=%s\n' "${GIT_CONFIG_GLOBAL:-}" "${GIT_CONFIG_NOSYSTEM:-}" >>"${TEST_ROOT}/git.log"
sub="" last=""
while (($# > 0)); do
  case "$1" in
    -C | -c) shift 2; continue ;;
    *) [[ -z "${sub}" ]] && sub="$1"; last="$1" ;;
  esac
  shift
done
case "${sub}" in
  clone) mkdir -p "${last}/.git" "${last}/user-settings/hosts" ;;
  remote) printf '%s\n' "${STUB_GIT_ORIGIN:-https://github.com/smartwatermelon/claude-config.git}" ;;
  diff) exit "${STUB_GIT_DIFF_RC:-1}" ;;
  push) exit "${STUB_GIT_PUSH_RC:-0}" ;;
  *) ;;
esac
exit 0
STUB
  # gh: logs argv and whether GH_TOKEN was set (never its value).
  cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >>"${TEST_ROOT}/gh.log"
if [[ "${GH_TOKEN:-}" == "${STUB_TOKEN}" ]]; then echo "env GH_TOKEN=app" >>"${TEST_ROOT}/gh.log"; fi
case "$1 $2" in
  "pr list") [[ -z "${STUB_GH_OPEN:-}" ]] || printf '%s\n' "${STUB_GH_OPEN}" ;;
  "pr create") echo "https://github.com/smartwatermelon/claude-config/pull/999" ;;
  *) ;;
esac
exit 0
STUB
  cat >"${TEST_ROOT}/bin/gitleaks" <<'STUB'
#!/usr/bin/env bash
printf 'gitleaks %s\n' "$*" >>"${TEST_ROOT}/gitleaks.log"
exit "${STUB_GITLEAKS_RC:-0}"
STUB
  cat >"${TEST_ROOT}/bin/notify" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_ROOT}/notify.log"
STUB
  # The App token helper: route, ensure, and --item <item> <owner> (prints the token).
  cat >"${TEST_ROOT}/bin/token" <<'STUB'
#!/usr/bin/env bash
printf 'token %s\n' "$1" >>"${TEST_ROOT}/token.log"
case "$1" in
  route) echo "op://Automation/smartwatermelon-agent app" ;;
  ensure)
    sleep "${STUB_MINT_SLEEP:-0}"
    exit "${STUB_MINT_RC:-0}"
    ;;
  --item) printf '%s\n' "${STUB_TOKEN}" ;;
  *) exit 2 ;;
esac
STUB
  cat >"${TEST_ROOT}/bin/security" <<'STUB'
#!/usr/bin/env bash
printf 'security %s\n' "$*" >>"${TEST_ROOT}/security.log"
exit "${STUB_KEYCHAIN_RC:-0}"
STUB
  chmod +x "${TEST_ROOT}"/bin/*
  : >"${TEST_ROOT}/git.log"
  : >"${TEST_ROOT}/gh.log"
  : >"${TEST_ROOT}/gitleaks.log"
  : >"${TEST_ROOT}/notify.log"
  : >"${TEST_ROOT}/token.log"
  : >"${TEST_ROOT}/security.log"
}

rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

write_base() { cat >"${SRC}/base.json"; }
write_host() { cat >"${SRC}/hosts/TESTHOST.json"; }

# live.json = what the deploy built (base + host + local), then the jq edit $1.
make_live() {
  local built="${TEST_ROOT}/built.json"
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" MACHINE_SETTINGS_HOST=TESTHOST bash "${BUILD}" \
    --src "${SRC}" --out "${built}" --report "${TEST_ROOT}/built.diff" --local "${LOCAL}" --host-optional >/dev/null
  jq "$1" "${built}" >"${LIVE}"
}

harvest() {
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" bash "${SCRIPT}" --live "${LIVE}" --src "${SRC}" \
    --host "${HOST_ARG:-TESTHOST}" --repo "${REPO}" --local "${LOCAL}" "$@"
}

pushed() { grep -qE '^git (.* )?push( |$)' "${TEST_ROOT}/git.log"; }
# Functions, not `! cmd`: bats does not fail a test on a negated command.
not_pushed() { if pushed; then return 1; fi; }
lacks() { if grep -q -- "$1" "$2"; then return 1; fi; }
gh_calls() { grep -c "^gh pr $1" "${TEST_ROOT}/gh.log" || true; }

# The value must be in no output, log, notification or argv record.
nowhere() {
  local v="$1" f
  [[ "${output}" != *"${v}"* ]] || return 1
  for f in "${TEST_ROOT}"/*.log; do
    if grep -qF -- "${v}" "${f}"; then
      echo "found in ${f}" >&2
      return 1
    fi
  done
}

host_json() { jq -cS . "${HOSTFILE}"; }

# --- test helpers ----------------------------------------------------------------

@test "the guarded stub refuses long options, .. paths and symlinked parents; it never runs the command" {
  local rec="${TEST_ROOT}/bin/recorder" g="${TEST_ROOT}/bin/guarded"
  printf '#!/usr/bin/env bash\necho ran >>"%s/recorder.log"\n' "${TEST_ROOT}" >"${rec}"
  chmod +x "${rec}"
  make_guarded_stub mv "${rec}" "${g}"
  mkdir -p "${TEST_ROOT}/in"
  # The command is a recorder, so a guard bug here can never reach a real mv.
  ln -s / "${TEST_ROOT}/in/link"
  run "${g}" -f "${TEST_ROOT}/in/link/x"
  [ "${status}" -eq 99 ]
  run "${g}" --target-directory=/ "${TEST_ROOT}/in/a"
  [ "${status}" -eq 99 ]
  run "${g}" -f "${TEST_ROOT}/in/../../x"
  [ "${status}" -eq 99 ]
  run "${g}" -f "relative/x"
  [ "${status}" -eq 99 ]
  [ ! -e "${TEST_ROOT}/recorder.log" ]
  run "${g}" -f "${TEST_ROOT}/in/a"
  [ "${status}" -eq 0 ]
  [ -s "${TEST_ROOT}/recorder.log" ]
}

@test "pushed() sees a bare git push (known-bad check for the no-push assertions)" {
  printf 'git push origin HEAD\n' >"${TEST_ROOT}/git.log"
  pushed
  printf 'git status\n' >"${TEST_ROOT}/git.log"
  not_pushed
}

# --- overlay ------------------------------------------------------------------

@test "an added permissions.allow rule becomes a host overlay holding only that rule" {
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"permissions":{"allow":["Bash(git status:*)"]}}' ]
  pushed
}

@test "a changed scalar (model) becomes a host overlay with the new value" {
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"model":"sonnet"}' ]
}

@test "the existing host file's content is kept in the new overlay" {
  write_host <<'JSON'
{"autoMode": {"environment": ["host note"]}}
JSON
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"autoMode":{"environment":["host note"]},"permissions":{"allow":["Bash(git status:*)"]}}' ]
}

@test "the local file's content never reaches the overlay" {
  printf '{"localOnly": "x", "permissions": {"allow": ["Bash(local:*)"]}}\n' >"${LOCAL}"
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"model":"sonnet"}' ]
}

@test "a base key removed locally is not harvestable: exit 3, notified, no push" {
  make_live 'del(.theme)'
  run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [ -s "${TEST_ROOT}/notify.log" ]
  [[ "${output}" == *"theme"* ]]
  nowhere '"dark"'
}

@test "the same refusal twice notifies once" {
  make_live 'del(.theme)'
  run harvest
  [ "${status}" -eq 3 ]
  run harvest
  [ "${status}" -eq 3 ]
  [ "$(wc -l <"${TEST_ROOT}/notify.log")" -eq 1 ]
}

@test "a policy key is not harvested: exit 3, no push" {
  make_live '.hooks = {"Stop": []}'
  run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [[ "${output}" == *"hooks"*"policy-key"* ]]
}

# --- secret checks -----------------------------------------------------------

@test "a gitleaks finding stops the harvest: exit 3, no push, the secret is not in the log" {
  local secret
  secret="tok$(rand_hex 6)"
  make_live ".permissions.allow += [\"Bash(echo ${secret}:*)\"]"
  STUB_GITLEAKS_RC=1 run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [[ "${output}" == *"gitleaks"* ]]
  [ -s "${TEST_ROOT}/notify.log" ]
  nowhere "${secret}"
}

@test "no gitleaks binary: exit 3, no push" {
  make_live '.model = "sonnet"'
  HARVEST_GITLEAKS_BIN="${TEST_ROOT}/bin/absent" run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [[ "${output}" == *"gitleaks"* ]]
}

@test "the shape check stops each secret gitleaks missed: exit 3, no push, the secret is not in the log" {
  local pw long rule
  for shape in bearer skproj mysql urluser postgres netlify; do
    make_stubs
    # A new notice each round: the harvest notifies once per distinct message.
    if [[ -d "${FAKE_HOME}/.local/state/claude-config" ]]; then
      : >"${FAKE_HOME}/.local/state/claude-config/harvest.notice"
    fi
    pw="$(rand_hex 6)"
    long="$(rand_hex 16)"
    case "${shape}" in
      bearer) rule="Bash(curl -H \\\"Authorization: Bearer ${pw}\\\" https://api.example.com:*)" ;;
      skproj) pw="sk-proj-${long}" && rule="Bash(llm -k ${pw}:*)" ;;
      mysql) rule="Bash(mysql -u app -p${pw} db:*)" ;;
      urluser) rule="Bash(curl https://user:${pw}@host.example.com:*)" ;;
      postgres) rule="Bash(psql postgresql://app:${pw}@db.example.com/app:*)" ;;
      netlify) rule="Bash(netlify deploy --auth ${pw}:*)" ;;
    esac
    make_live ".permissions.allow += [\"${rule}\"]"
    run harvest
    echo "shape ${shape}: status ${status}: ${output}"
    [ "${status}" -eq 3 ]
    not_pushed
    [[ "${output}" == *"permissions.allow.0: secret-shaped-string"* ]]
    [[ "${output}" != *"rule-shape"* ]]
    [ -s "${TEST_ROOT}/notify.log" ]
    nowhere "${pw}"
  done
}

@test "a new env value stops the harvest: exit 3, no push" {
  make_live '.env = {"FOO": "bar"}'
  run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [[ "${output}" == *"env.FOO"*"env-value"* ]]
  nowhere '"bar"'
}

@test "an exact-command allow rule stops the harvest; a prefix rule passes" {
  make_live '.permissions.allow += ["Bash(npm run build)"]'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"rule-shape"* ]]
  not_pushed

  make_stubs
  make_live '.permissions.allow += ["Bash(npm run build:*)", "Bash(npm test *)", "WebFetch"]'
  run harvest
  [ "${status}" -eq 0 ]
  pushed
}

# --- credentials -------------------------------------------------------------

@test "no Keychain item for the App key: exit 3 names the missing credential, nothing minted or pushed" {
  make_live '.model = "sonnet"'
  STUB_KEYCHAIN_RC=44 run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"no App credential"* ]]
  lacks '^token ensure' "${TEST_ROOT}/token.log"
  not_pushed
  [ -s "${TEST_ROOT}/notify.log" ]
}

@test "a mint that hangs is stopped by the timeout: exit 3, no push" {
  make_live '.model = "sonnet"'
  STUB_MINT_SLEEP=20 HARVEST_TIMEOUT=1 run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"no App credential"* ]]
  not_pushed
}

@test "git runs without global config, as the App bot, over the App credential helper" {
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  lacks '^env GIT_CONFIG_GLOBAL= ' "${TEST_ROOT}/git.log"
  grep -q '^env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1' "${TEST_ROOT}/git.log"
  grep -q 'user.name=smartwatermelon-agent\[bot\] .*commit' "${TEST_ROOT}/git.log"
  grep -q 'credential.helper=!.* git-credential .*push --force-with-lease' "${TEST_ROOT}/git.log"
  grep -q "push --force-with-lease .*origin HEAD:refs/heads/${BRANCH}" "${TEST_ROOT}/git.log"
  grep -q '^env GH_TOKEN=app' "${TEST_ROOT}/gh.log"
  nowhere "${STUB_TOKEN}"
}

@test "an ARICH-MAC host is refused: company settings never reach this repo" {
  make_live '.model = "sonnet"'
  HOST_ARG=ARICH-MAC run harvest
  [ "${status}" -eq 3 ]
  not_pushed
}

@test "a scratch clone whose origin is not the https URL is refused: exit 1, no push" {
  make_live '.model = "sonnet"'
  STUB_GIT_ORIGIN="git@github.com:${REPO}.git" run harvest
  [ "${status}" -eq 1 ]
  not_pushed
  [ "$(gh_calls create)" -eq 0 ]
}

@test "a failed push: exit 1, no PR" {
  make_live '.model = "sonnet"'
  STUB_GIT_PUSH_RC=1 run harvest
  [ "${status}" -eq 1 ]
  [ "$(gh_calls list)" -eq 0 ]
  [ "$(gh_calls create)" -eq 0 ]
}

# --- PR ----------------------------------------------------------------------

@test "an open harvest PR is updated by push, not duplicated" {
  make_live '.model = "sonnet"'
  STUB_GH_OPEN="https://github.com/${REPO}/pull/5" run harvest
  [ "${status}" -eq 0 ]
  pushed
  [ "$(gh_calls list)" -eq 1 ]
  [ "$(gh_calls create)" -eq 0 ]
}

@test "no open PR: gh pr create is called once with the branch" {
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(gh_calls create)" -eq 1 ]
  grep -q "^gh pr create .*--head ${BRANCH}" "${TEST_ROOT}/gh.log"
  grep -q "^gh pr create .*-R ${REPO}" "${TEST_ROOT}/gh.log"
}

@test "--dry-run pushes nothing and creates no PR" {
  make_live '.model = "sonnet"'
  run harvest --dry-run
  [ "${status}" -eq 0 ]
  [ ! -s "${TEST_ROOT}/git.log" ]
  [ ! -s "${TEST_ROOT}/gh.log" ]
  [ ! -s "${TEST_ROOT}/token.log" ]
}

@test "no difference from the last build: exit 0, nothing pushed" {
  make_live '.'
  run harvest
  [ "${status}" -eq 0 ]
  not_pushed
}
