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
  WORK="${FAKE_HOME}/.local/share/claude-config-harvest"
  HOSTFILE="${WORK}/user-settings/hosts/TESTHOST.json"
  STUB_LOG="${TEST_ROOT}/stub.log"
  mkdir -p "${FAKE_HOME}" "${SRC}/hosts" "${TEST_ROOT}/tmp" "${TEST_ROOT}/bin"
  : >"${STUB_LOG}"
  make_guarded_stub mv
  make_guarded_stub rm
  make_guarded_stub cp
  make_stubs
  export MACHINE_SETTINGS_MV_BIN="${TEST_ROOT}/bin/mv"
  export MACHINE_SETTINGS_RM_BIN="${TEST_ROOT}/bin/rm"
  export HARVEST_MV_BIN="${TEST_ROOT}/bin/mv"
  export HARVEST_RM_BIN="${TEST_ROOT}/bin/rm"
  export HARVEST_CP_BIN="${TEST_ROOT}/bin/cp"
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
printf 'env GIT_CONFIG_GLOBAL=%s GIT_CONFIG_NOSYSTEM=%s GIT_DIR=%s GIT_WORK_TREE=%s\n' "${GIT_CONFIG_GLOBAL:-}" \
  "${GIT_CONFIG_NOSYSTEM:-}" "${GIT_DIR:-}" "${GIT_WORK_TREE:-}" >>"${TEST_ROOT}/git.log"
printf 'ident author=%s <%s> committer=%s <%s>\n' "${GIT_AUTHOR_NAME:-}" "${GIT_AUTHOR_EMAIL:-}" \
  "${GIT_COMMITTER_NAME:-}" "${GIT_COMMITTER_EMAIL:-}" >>"${TEST_ROOT}/git.log"
all=" $* " sub="" last="" branch_ref=false dir=""
while (($# > 0)); do
  case "$1" in
    -C) dir="$2"; shift 2; continue ;;
    -c) shift 2; continue ;;
    refs/remotes/origin/claude/*) branch_ref=true ;;
    *) ;;
  esac
  [[ -z "${sub}" ]] && sub="$1"
  last="$1"
  shift
done
case "${sub}" in
  clone) mkdir -p "${last}/.git" "${last}/user-settings/hosts" ;;
  # origin/main's user-settings/: STUB_MAIN_SRC, default the test's --src.
  checkout) cp -R "${STUB_MAIN_SRC:-${TEST_ROOT}/src}/." "${dir}/user-settings/" ;;
  remote)
    url="${STUB_GIT_ORIGIN:-https://github.com/smartwatermelon/claude-config.git}"
    [[ "${all}" == *" --push "* ]] && url="${STUB_GIT_PUSHURL:-${url}}"
    printf '%s\n' "${url}"
    ;;
  # The harvest branch on origin: absent unless STUB_GIT_BRANCH_SAME=1, then it has the same host file.
  rev-parse) ${branch_ref} && [[ -z "${STUB_GIT_BRANCH_SAME:-}" ]] && exit 1 ;;
  diff)
    ${branch_ref} && exit 0
    exit "${STUB_GIT_DIFF_RC:-1}"
    ;;
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
  "pr create" | "pr edit")
    # The body file is in the harvest's temp dir, gone after it exits: keep a copy.
    prev=""
    for a in "$@"; do
      [[ "${prev}" != --body-file ]] || cp "${a}" "${TEST_ROOT}/body.md"
      prev="${a}"
    done
    [[ "$2" != create ]] || echo "https://github.com/smartwatermelon/claude-config/pull/999"
    [[ "$2" != edit ]] || exit "${STUB_GH_EDIT_RC:-0}"
    ;;
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
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" MACHINE_SETTINGS_HOST="${HOST_ARG:-TESTHOST}" bash "${BUILD}" \
    --src "${SRC}" --out "${built}" --report "${TEST_ROOT}/built.diff" --local "${LOCAL}" --host-optional >/dev/null
  jq "$1" "${built}" >"${LIVE}"
  cp "${built}" "${LIVE}.built"
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

# --- fan-out helpers -----------------------------------------------------------

GROUPFILE_REL="user-settings/groups/personal.json"
HOSTFILE_REL="user-settings/hosts/TESTHOST.json"
RISK_LIST="${BATS_TEST_DIRNAME:?}/../user-settings/host-only-rules.txt"

# TESTHOST in the personal group (empty layer), with the repo's own risk list.
use_group() {
  mkdir -p "${SRC}/groups"
  printf '{"personal": ["TESTHOST"]}\n' >"${SRC}/groups.json"
  printf '{}\n' >"${SRC}/groups/personal.json"
  cp "${RISK_LIST}" "${SRC}/host-only-rules.txt"
}
group_json() { jq -c . "${WORK}/${GROUPFILE_REL}"; }
# The folded allow rules of the group file and of the host file, as compact JSON arrays.
group_rules() { jq -c '.permissions.allow // []' "${WORK}/${GROUPFILE_REL}"; }
host_rules() { jq -c '.permissions.allow // []' "${HOSTFILE}"; }
staged() { grep -qE "^git (.* )?add -- $1\$" "${TEST_ROOT}/git.log"; }
not_staged() { if staged "$1"; then return 1; fi; }
# The rules listed under a PR-body heading: the lines from "### $1" to the next heading.
body_section() { awk -v h="### $1" 'index($0, h) == 1 { on = 1; next } /^### |^Fold into/ { on = 0 } on' "${TEST_ROOT}/body.md"; }

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

@test "gap 4: main gained an allow rule the live file lacks; the new local rule is still harvested alone" {
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  # After the last build, main's base gains a rule this Mac has not built yet.
  write_base <<'JSON'
{"model": "opus", "theme": "dark", "permissions": {"allow": ["Bash(ls:*)", "Bash(pwd)"]}, "enabledPlugins": {"a@m": true}}
JSON
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"permissions":{"allow":["Bash(git status:*)"]}}' ]
  pushed
}

@test "main's newer host file content is kept, and only the part of D main lacks is folded" {
  make_live '.model = "sonnet" | .permissions.allow += ["Bash(git status:*)"]'
  # origin/main moved on: this host file gained a key, and base gained the local rule.
  mkdir -p "${TEST_ROOT}/main/hosts"
  jq '.permissions.allow += ["Bash(git status:*)"]' "${SRC}/base.json" >"${TEST_ROOT}/main/base.json"
  printf '{"autoMode": {"environment": ["from main"]}}\n' >"${TEST_ROOT}/main/hosts/TESTHOST.json"
  STUB_MAIN_SRC="${TEST_ROOT}/main" run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"autoMode":{"environment":["from main"]},"model":"sonnet"}' ]
  pushed
}

@test "origin/main already holds every local change: exit 0, nothing pushed" {
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  mkdir -p "${TEST_ROOT}/main/hosts"
  jq '.permissions.allow += ["Bash(git status:*)"]' "${SRC}/base.json" >"${TEST_ROOT}/main/base.json"
  STUB_MAIN_SRC="${TEST_ROOT}/main" run harvest
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already holds every local change"* ]]
  not_pushed
  [ "$(gh_calls create)" -eq 0 ]
}

@test "a fold the build cannot make hold the change is refused: exit 3, no push" {
  make_live '.extra = {"a": 1}'
  # Main's base made extra a string: the folded object clashes with it.
  mkdir -p "${TEST_ROOT}/main/hosts"
  jq '.extra = "s"' "${SRC}/base.json" >"${TEST_ROOT}/main/base.json"
  STUB_MAIN_SRC="${TEST_ROOT}/main" run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"folded host file"* ]]
  not_pushed
}

@test "a change the local file overrides cannot be held by a host fold: exit 3, no push" {
  printf '{"model": "haiku"}\n' >"${LOCAL}"
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"does not hold every local change (keys: model)"* ]]
  not_pushed
}

@test "a removed array item is not harvestable: exit 3, only the key is named" {
  make_live '.permissions.allow -= ["Bash(ls:*)"] | .model = "sonnet"'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"removes something"*"permissions"* ]]
  not_pushed
  nowhere 'Bash(ls'
}

@test "an allow rule only this host's file supplies, removed locally, is dropped from the host file" {
  write_host <<'JSON'
{"permissions": {"allow": ["Bash(host:*)"]}}
JSON
  make_live '.permissions.allow -= ["Bash(host:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{}' ]
  pushed
}

@test "an allow rule base.json supplies, removed locally, is refused: exit 3, no push" {
  write_host <<'JSON'
{"permissions": {"allow": ["Bash(host:*)"]}}
JSON
  make_live '.permissions.allow -= ["Bash(ls:*)"]'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"removes something"*"permissions"* ]]
  not_pushed
  nowhere 'Bash(ls'
}

@test "an allow rule only a group file supplies, removed locally, is refused: exit 3, no push" {
  printf '{"personal": ["TESTHOST"]}\n' >"${SRC}/groups.json"
  mkdir -p "${SRC}/groups"
  printf '{"permissions": {"allow": ["Bash(group:*)"]}}\n' >"${SRC}/groups/personal.json"
  write_host <<'JSON'
{"permissions": {"allow": ["Bash(host:*)"]}}
JSON
  make_live '.permissions.allow -= ["Bash(group:*)"]'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"a group file"*"permissions"* ]]
  not_pushed
  # The dry run folds into --src and must refuse the same way.
  make_stubs
  run harvest --dry-run
  [ "${status}" -eq 3 ]
}

@test "a local rule main's group file already holds is not folded into the host file" {
  make_live '.permissions.allow += ["Bash(group:*)"]'
  mkdir -p "${TEST_ROOT}/main/hosts" "${TEST_ROOT}/main/groups"
  cp "${SRC}/base.json" "${TEST_ROOT}/main/base.json"
  printf '{"personal": ["TESTHOST"]}\n' >"${TEST_ROOT}/main/groups.json"
  printf '{"permissions": {"allow": ["Bash(group:*)"]}}\n' >"${TEST_ROOT}/main/groups/personal.json"
  STUB_MAIN_SRC="${TEST_ROOT}/main" run harvest
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already holds every local change"* ]]
  not_pushed
}

@test "a removal and an addition in one edit are both in the fold" {
  write_host <<'JSON'
{"permissions": {"allow": ["Bash(host:*)", "Bash(keep:*)"]}}
JSON
  make_live '.permissions.allow -= ["Bash(host:*)"] | .permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"permissions":{"allow":["Bash(keep:*)","Bash(git status:*)"]}}' ]
  pushed
}

@test "a key only the host file supplies is dropped; one base.json also has is refused" {
  write_host <<'JSON'
{"hostOnly": "x", "model": "sonnet"}
JSON
  make_live 'del(.hostOnly)'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"model":"sonnet"}' ]
  make_stubs
  make_live 'del(.model)'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"removes something"*"model"* ]]
  not_pushed
}

@test "an object replaced by a scalar counts as a removal: exit 3, no push" {
  make_live '.enabledPlugins = false'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"removes something"*"enabledPlugins"* ]]
  not_pushed
}

@test "no record of the last build: exit 1, nothing pushed" {
  make_live '.model = "sonnet"'
  printf 'not json\n' >"${LIVE}.built"
  run harvest
  [ "${status}" -eq 1 ]
  not_pushed
}

@test "--built names the record of the last build" {
  make_live '.model = "sonnet"'
  cp "${LIVE}.built" "${TEST_ROOT}/elsewhere.built"
  printf 'not json\n' >"${LIVE}.built"
  run harvest --built "${TEST_ROOT}/elsewhere.built"
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"model":"sonnet"}' ]
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

@test "exact-command, prefix and bare-tool allow rules are all harvested" {
  make_live '.permissions.allow += ["Bash(gitleaks version)", "Bash(npm run build:*)", "Bash(npm test *)", "WebFetch"]'
  run harvest
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"rule-shape"* ]]
  pushed
}

@test "an exact-command allow rule holding a secret still stops the harvest" {
  local pw
  pw="$(rand_hex 6)"
  make_live ".permissions.allow += [\"Bash(mysql -u app -p${pw} db)\"]"
  run harvest
  [ "${status}" -eq 3 ]
  not_pushed
  [[ "${output}" == *"permissions.allow.0: secret-shaped-string"* ]]
  nowhere "${pw}"
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

@test "no Keychain item but a key file: the harvest mints through the helper" {
  make_live '.model = "sonnet"'
  mkdir -p "${FAKE_HOME}/.config/gh-app-keys"
  key="${FAKE_HOME}/.config/gh-app-keys/smartwatermelon-agent app.pem"
  printf -- '-----BEGIN PRIVATE KEY-----\nstub\n-----END PRIVATE KEY-----\n' >"${key}"
  chmod 600 "${key}"
  STUB_KEYCHAIN_RC=44 run harvest
  [ "${status}" -eq 0 ]
  grep -q '^token ensure' "${TEST_ROOT}/token.log"
  pushed
}

@test "a key file that is a symlink does not count: exit 3, nothing minted" {
  make_live '.model = "sonnet"'
  mkdir -p "${FAKE_HOME}/.config/gh-app-keys"
  printf 'x\n' >"${TEST_ROOT}/elsewhere.pem"
  ln -s "${TEST_ROOT}/elsewhere.pem" "${FAKE_HOME}/.config/gh-app-keys/smartwatermelon-agent app.pem"
  STUB_KEYCHAIN_RC=44 run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"no key file"* ]]
  lacks '^token ensure' "${TEST_ROOT}/token.log"
  not_pushed
}

@test "an unreadable key file does not count: exit 3, nothing minted" {
  make_live '.model = "sonnet"'
  mkdir -p "${FAKE_HOME}/.config/gh-app-keys"
  key="${FAKE_HOME}/.config/gh-app-keys/smartwatermelon-agent app.pem"
  printf 'x\n' >"${key}"
  chmod 000 "${key}"
  STUB_KEYCHAIN_RC=44 run harvest
  chmod 600 "${key}"
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"no key file"* ]]
  lacks '^token ensure' "${TEST_ROOT}/token.log"
  not_pushed
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
  # A caller's identity env (claude-wrapper sets one) must not reach the commit.
  GIT_AUTHOR_NAME=Someone GIT_AUTHOR_EMAIL=someone@example.com GIT_COMMITTER_NAME=Someone \
    GIT_COMMITTER_EMAIL=someone@example.com GIT_DIR="${TEST_ROOT}/other/.git" \
    GIT_WORK_TREE="${TEST_ROOT}/other" run harvest
  [ "${status}" -eq 0 ]
  lacks '^env GIT_CONFIG_GLOBAL= ' "${TEST_ROOT}/git.log"
  grep -q '^env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_DIR= GIT_WORK_TREE=$' "${TEST_ROOT}/git.log"
  lacks 'GIT_DIR=/' "${TEST_ROOT}/git.log"
  grep -q 'user.name=smartwatermelon-agent\[bot\] .*commit' "${TEST_ROOT}/git.log"
  grep -A2 'commit --quiet' "${TEST_ROOT}/git.log" | grep -q \
    '^ident author=smartwatermelon-agent\[bot\] <345515361+smartwatermelon-agent\[bot\]@users.noreply.github.com> committer=smartwatermelon-agent\[bot\] <'
  grep -q 'credential.helper=!.* git-credential .*push --force-with-lease' "${TEST_ROOT}/git.log"
  grep -q "push --force-with-lease .*origin HEAD:refs/heads/${BRANCH}" "${TEST_ROOT}/git.log"
  grep -q '^env GH_TOKEN=app' "${TEST_ROOT}/gh.log"
  nowhere "${STUB_TOKEN}"
}


@test "the scratch clone is made outside the sandbox-writable ~/.local/state" {
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  pushed
  grep -qE "^git (.* )?clone .* ${WORK}\$" "${TEST_ROOT}/git.log"
  [ -d "${WORK}/.git" ]
  [ ! -e "${FAKE_HOME}/.local/state/claude-config/harvest" ]
}

@test "a scratch clone whose origin is not the https URL is refused: exit 1, no push" {
  make_live '.model = "sonnet"'
  STUB_GIT_ORIGIN="git@github.com:${REPO}.git" run harvest
  [ "${status}" -eq 1 ]
  not_pushed
  [ "$(gh_calls create)" -eq 0 ]
}

@test "a push URL that is not the https URL is refused: exit 1, no push" {
  make_live '.model = "sonnet"'
  STUB_GIT_PUSHURL="git@github.com:${REPO}.git" run harvest
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"pushes to"* ]]
  not_pushed
}

@test "with local-file array items, a new rule in that array is harvested alone" {
  printf '{"permissions": {"allow": ["Bash(local:*)"]}}\n' >"${LOCAL}"
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"permissions":{"allow":["Bash(git status:*)"]}}' ]
  pushed
}

@test "a failed push: exit 1, no PR" {
  make_live '.model = "sonnet"'
  STUB_GIT_PUSH_RC=1 run harvest
  [ "${status}" -eq 1 ]
  [ "$(gh_calls list)" -eq 0 ]
  [ "$(gh_calls create)" -eq 0 ]
}

# --- fan-out: group file or host file ----------------------------------------

@test "fan-out: a low-risk exact rule goes to groups/personal.json; the host file is unchanged" {
  use_group
  write_host <<'JSON'
{"model": "sonnet"}
JSON
  cp "${SRC}/hosts/TESTHOST.json" "${TEST_ROOT}/host-before.json"
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(group_json)" = '{"permissions":{"allow":["Bash(git status)"]}}' ]
  cmp "${HOSTFILE}" "${TEST_ROOT}/host-before.json"
  staged "${GROUPFILE_REL}"
  not_staged "${HOSTFILE_REL}"
  [[ "${output}" == *"new allow rules: 1 to ${GROUPFILE_REL}, 0 to ${HOSTFILE_REL}"* ]]
  pushed
}

@test "fan-out: risk-list rules stay in the host file, prefixed forms too" {
  use_group
  local rules='["Bash(rm x)", "Bash(sudo rm x)", "Bash(cd x && rm y)", "Bash(xargs rm)", "Bash(git -C /p push)",
    "Bash(ssh-keygen -t ed25519)", "Bash(cat ~/.ssh/config)", "Bash(RM x)", "Bash(gh pr merge 5)",
    "Bash(find . -name x -delete)", "Bash(git branch -D x)", "Bash(npm publish)", "Bash(killall x)",
    "Bash(defaults write a b c)", "Bash(wrangler deploy)", "Bash(eas build)", "Bash(ls 2>/dev/null)",
    "Bash(git branch -q -D old)", "Bash(git branch old -D)", "Bash(git branch -dr origin/x)",
    "Bash(gh pr -R o/r merge 5)", "Bash(gh repo -R o/r delete)"]'
  make_live ".permissions.allow += ${rules}"
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = "$(jq -c . <<<"${rules}")" ]
  [ "$(group_json)" = '{}' ]
  staged "${HOSTFILE_REL}"
  not_staged "${GROUPFILE_REL}"
}

@test "fan-out: words that only contain a risky command are not caught by it" {
  use_group
  # perform holds rm, add holds dd, release holds eas, stop holds op, gitleaks holds git.
  local rules='["Bash(npm run perform)", "Bash(git add x)", "Bash(npm run release)", "Bash(npm stop)",
    "Bash(gitleaks version)", "Bash(git log --oneline)", "Bash(bats tests/test_x.bats)",
    "Bash(git branch --show-current)", "Bash(gh pr view 5)"]'
  make_live ".permissions.allow += ${rules}"
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(group_rules)" = "$(jq -c . <<<"${rules}")" ]
  [ ! -e "${HOSTFILE}" ]
  not_staged "${HOSTFILE_REL}"
}

@test "fan-out: a non-Bash rule, a wildcard Bash rule and bare Bash stay on the host with an empty risk list" {
  use_group
  # One pattern no rule here matches, so only the built-in checks act.
  printf '# one unrelated pattern\n^never-matches$\n' >"${SRC}/host-only-rules.txt"
  make_live '.permissions.allow += ["WebFetch", "Read(~/x)", "mcp__srv__tool", "Bash", "Bash(*)",
    "Bash(npm test *)", "Bash(git status:*)", "Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["WebFetch","Read(~/x)","mcp__srv__tool","Bash","Bash(*)","Bash(npm test *)","Bash(git status:*)"]' ]
  # The list is in effect: the one exact rule fans out.
  [ "$(group_rules)" = '["Bash(git status)"]' ]
}

@test "fan-out: in-place edits, interpreter one-liners, gh release and credential files stay on the host" {
  use_group
  local risky='["Bash(sed -i s/a/b/ f)", "Bash(perl -i x.pl f)", "Bash(bash -c x)", "Bash(python3 -c 1)",
    "Bash(node -e 1)", "Bash(node -p 1)", "Bash(node --print 1)", "Bash(gsed -i s/a/b/ f)", "Bash(python3 -cprint(1))",
    "Bash(php -r x)", "Bash(deno eval x)", "Bash(bun -e x)", "Bash(awk {print} f)",
    "Bash(gh release create v1)", "Bash(gh repo create x)", "Bash(git worktree remove x)",
    "Bash(cat ~/.npmrc)", "Bash(cat ~/.config/gh/hosts.yml)"]'
  # The "Bash(" wrapper is not the bash interpreter: a -C or -e flag alone keeps nothing local.
  local safe='["Bash(git -C /p log)", "Bash(grep -e foo x)", "Bash(sed -n 1p f)", "Bash(git worktree list)"]'
  make_live ".permissions.allow += ${risky} + ${safe}"
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = "$(jq -c . <<<"${risky}")" ]
  [ "$(group_rules)" = "$(jq -c . <<<"${safe}")" ]
}

@test "fan-out: a risk list with no patterns keeps every rule in the host file, logged as an error" {
  use_group
  printf '# no patterns\n\n' >"${SRC}/host-only-rules.txt"
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["Bash(git status)"]' ]
  [ "$(group_rules)" = '[]' ]
  [[ "${output}" == *"ERROR: the risk list holds no patterns"* ]]
}

@test "fan-out: a mixed delta stages both files, and the PR body lists each rule under its heading" {
  use_group
  make_live '.permissions.allow += ["Bash(git status)", "Bash(rm -f x)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(group_rules)" = '["Bash(git status)"]' ]
  [ "$(host_rules)" = '["Bash(rm -f x)"]' ]
  staged "${GROUPFILE_REL}"
  staged "${HOSTFILE_REL}"
  [ "$(body_section 'Personal Macs (groups/personal.json)' | grep -c '^Bash(')" -eq 1 ]
  body_section 'Personal Macs (groups/personal.json)' | grep -qxF 'Bash(git status)'
  [ "$(body_section 'This Mac only (hosts/TESTHOST.json)' | grep -c '^Bash(')" -eq 1 ]
  body_section 'This Mac only (hosts/TESTHOST.json)' | grep -qxF 'Bash(rm -f x)'
  grep -q 'is a grant' "${TEST_ROOT}/body.md"
  grep -qF -- "--- main:${GROUPFILE_REL}" "${TEST_ROOT}/body.md"
  grep -qF -- "--- main:${HOSTFILE_REL}" "${TEST_ROOT}/body.md"
  # With the branch on origin, its check compares both files.
  make_stubs
  STUB_GIT_BRANCH_SAME=1 run harvest
  [ "${status}" -eq 0 ]
  grep -qF "diff --cached --quiet refs/remotes/origin/${BRANCH} -- ${HOSTFILE_REL} ${GROUPFILE_REL}" "${TEST_ROOT}/git.log"
}

@test "fan-out: an empty list reads None. under its heading, for both headings" {
  use_group
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(body_section 'This Mac only (hosts/TESTHOST.json)' | grep -c .)" -eq 1 ]
  body_section 'This Mac only (hosts/TESTHOST.json)' | grep -qx 'None\.'
  lacks "main:${HOSTFILE_REL}" "${TEST_ROOT}/body.md"
  make_stubs
  make_live '.permissions.allow += ["Bash(rm x)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(body_section 'Personal Macs (groups/personal.json)' | grep -c .)" -eq 1 ]
  body_section 'Personal Macs (groups/personal.json)' | grep -qx 'None\.'
}

@test "fan-out: a host in no group keeps every rule in the host file, logged" {
  use_group
  printf '{"personal": ["OTHERHOST"]}\n' >"${SRC}/groups.json"
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["Bash(git status)"]' ]
  [ "$(group_json)" = '{}' ]
  not_staged "${GROUPFILE_REL}"
  [[ "${output}" == *"TESTHOST is in no group"* ]]
  grep -q '^None: TESTHOST is in no group' "${TEST_ROOT}/body.md"
}

@test "fan-out: a host in two groups keeps every rule in the host file, logged" {
  use_group
  printf '{"personal": ["TESTHOST"], "lab": ["TESTHOST"]}\n' >"${SRC}/groups.json"
  printf '{}\n' >"${SRC}/groups/lab.json"
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["Bash(git status)"]' ]
  [ "$(group_json)" = '{}' ]
  [[ "${output}" == *"TESTHOST is in 2 groups, not one"* ]]
}

@test "fan-out: a missing risk list keeps every rule in the host file, logged as an error" {
  use_group
  "${TEST_ROOT}/bin/rm" -f "${SRC}/host-only-rules.txt"
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["Bash(git status)"]' ]
  [ "$(group_json)" = '{}' ]
  [[ "${output}" == *"ERROR: the risk list host-only-rules.txt is missing or unreadable"* ]]
  grep -q 'Every new rule stays on this Mac: the risk list' "${TEST_ROOT}/body.md"
}

@test "fan-out: an invalid pattern in the risk list keeps every rule in the host file, logged as an error" {
  use_group
  local bad
  for bad in '(unclosed' 'a[b'; do
    make_stubs
    # The last round's fold is still in the scratch clone; start from main again.
    [[ ! -e "${HOSTFILE}" ]] || "${TEST_ROOT}/bin/rm" -f "${HOSTFILE}"
    printf '%s\n' '(^|[^A-Za-z0-9_])rm([^A-Za-z0-9_]|$)' "${bad}" >"${SRC}/host-only-rules.txt"
    make_live '.permissions.allow += ["Bash(git status)"]'
    run harvest
    echo "pattern ${bad}: ${output}"
    [ "${status}" -eq 0 ]
    [ "$(host_rules)" = '["Bash(git status)"]' ]
    [ "$(group_json)" = '{}' ]
    [[ "${output}" == *"ERROR: the risk list holds an invalid pattern (grep exit 2)"* ]]
  done
}

@test "fan-out: blank, comment and CRLF lines in the risk list are not patterns" {
  use_group
  # Unstripped, the blank line would match every rule and keep Bash(git status) on the host.
  printf '# comment\n\n   \n\t# indented comment\r\n(^|[^A-Za-z0-9_])rm([^A-Za-z0-9_]|$)\r\n' >"${SRC}/host-only-rules.txt"
  make_live '.permissions.allow += ["Bash(git status)", "Bash(rm x)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(group_rules)" = '["Bash(git status)"]' ]
  [ "$(host_rules)" = '["Bash(rm x)"]' ]
  [[ "${output}" != *"ERROR"* ]]
}

@test "fan-out: a split the build check rejects falls back to the host file, and the PR body says so" {
  use_group
  # A build that rejects any dry run whose group file holds a Bash rule: the split check fails, all-host passes.
  cat >"${TEST_ROOT}/bin/build" <<STUB
#!/usr/bin/env bash
src="" dry=false
for a in "\$@"; do
  [[ "\${prev:-}" != --src ]] || src="\${a}"
  [[ "\${a}" != --dry-run ]] || dry=true
  prev="\${a}"
done
if \${dry} && grep -q 'Bash(' "\${src}/groups/personal.json" 2>/dev/null; then exit 2; fi
exec bash "${BUILD}" "\$@"
STUB
  make_live '.permissions.allow += ["Bash(git status)"]'
  HARVEST_BUILD_BIN="${TEST_ROOT}/bin/build" run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_rules)" = '["Bash(git status)"]' ]
  [ "$(group_json)" = '{}' ]
  not_staged "${GROUPFILE_REL}"
  [[ "${output}" == *"the build check failed (exit 2) with rules in ${GROUPFILE_REL}"* ]]
  grep -q 'The build check failed with the rules split across files' "${TEST_ROOT}/body.md"
  body_section 'This Mac only (hosts/TESTHOST.json)' | grep -qxF 'Bash(git status)'
}

@test "fan-out: the host and group files keep their key order" {
  use_group
  printf '{"zeta": 1, "permissions": {"allow": ["Bash(h1)"]}, "alpha": 2}\n' >"${SRC}/groups/personal.json"
  write_host <<'JSON'
{"zeta": 3, "permissions": {"allow": ["Bash(h2)"]}, "alpha": 4}
JSON
  make_live '.permissions.allow += ["Bash(git status)", "Bash(rm x)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(group_json)" = '{"zeta":1,"permissions":{"allow":["Bash(h1)","Bash(git status)"]},"alpha":2}' ]
  [ "$(jq -c . "${HOSTFILE}")" = '{"zeta":3,"permissions":{"allow":["Bash(h2)","Bash(rm x)"]},"alpha":4}' ]
}

@test "fan-out: a key other than permissions.allow stays in the host file" {
  use_group
  make_live '.model = "sonnet" | .permissions.allow += ["Bash(git status)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(host_json)" = '{"model":"sonnet"}' ]
  [ "$(group_rules)" = '["Bash(git status)"]' ]
}

@test "fan-out: the dry run names the group file it would set" {
  use_group
  make_live '.permissions.allow += ["Bash(git status)"]'
  run harvest --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"would set ${GROUPFILE_REL} on"* ]]
  [ ! -s "${TEST_ROOT}/git.log" ]
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

@test "an open harvest PR gets a new body that lists the rules its branch now holds" {
  use_group
  make_live '.permissions.allow += ["Bash(git status)", "Bash(rm -f x)"]'
  STUB_GH_OPEN="https://github.com/${REPO}/pull/5" run harvest
  [ "${status}" -eq 0 ]
  [ "$(gh_calls edit)" -eq 1 ]
  [ "$(gh_calls create)" -eq 0 ]
  grep -q 'pr edit https://github.com/.*/pull/5 ' "${TEST_ROOT}/gh.log"
  grep -qF 'Bash(git status)' "${TEST_ROOT}/body.md"
  grep -qF 'Bash(rm -f x)' "${TEST_ROOT}/body.md"
  [[ "${output}" == *"updated the open PR"*"and its body"* ]]
}

@test "a failed body update on an open PR fails loudly" {
  make_live '.model = "sonnet"'
  STUB_GH_EDIT_RC=1 STUB_GH_OPEN="https://github.com/${REPO}/pull/5" run harvest
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"gh pr edit failed"* ]]
}

@test "the branch already has this host file: no new push; an open PR gets only a body update" {
  make_live '.model = "sonnet"'
  STUB_GIT_BRANCH_SAME=1 STUB_GH_OPEN="https://github.com/${REPO}/pull/5" run harvest
  [ "${status}" -eq 0 ]
  not_pushed
  lacks ' commit ' "${TEST_ROOT}/git.log"
  [ "$(gh_calls create)" -eq 0 ]
  [ "$(gh_calls edit)" -eq 1 ]
}

@test "the branch has this host file but no PR is open: a PR is opened, nothing pushed" {
  make_live '.model = "sonnet"'
  STUB_GIT_BRANCH_SAME=1 run harvest
  [ "${status}" -eq 0 ]
  not_pushed
  [ "$(gh_calls create)" -eq 1 ]
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
  [[ "${output}" == *"would set"* ]]
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

# --- local mode (work machines) -----------------------------------------------

# A work-machine host name, in this one place: local mode is chosen by host.
work_host() { export HOST_ARG=ARICH-MAC; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# Nothing left the Mac: no git, gh, gitleaks or App token call.
stayed_local() {
  [ ! -s "${TEST_ROOT}/git.log" ]
  [ ! -s "${TEST_ROOT}/gh.log" ]
  [ ! -s "${TEST_ROOT}/gitleaks.log" ]
  [ ! -s "${TEST_ROOT}/token.log" ]
  [ ! -e "${WORK}" ]
}
# The local file is byte-for-byte the saved copy, and no backup or temp file was left.
untouched() {
  cmp -s "${TEST_ROOT}/local.orig" "${LOCAL}"
  [ ! -e "${LOCAL}.bak" ]
  [ -z "$(find "${TEST_ROOT}" -maxdepth 1 -name '.user-settings.local.*')" ]
}
save_local() { cp "${LOCAL}" "${TEST_ROOT}/local.orig"; }

@test "local mode: a new wildcard allow rule goes into the local file; nothing leaves the Mac" {
  work_host
  printf '{"localOnly": "x", "model": "local-model"}\n' >"${LOCAL}"
  save_local
  make_live '.permissions.allow += ["Bash(gh issue list:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(jq -c '.permissions.allow' "${LOCAL}")" = '["Bash(gh issue list:*)"]' ]
  [ "$(jq -cS 'del(.permissions)' "${LOCAL}")" = '{"localOnly":"x","model":"local-model"}' ]
  cmp -s "${TEST_ROOT}/local.orig" "${LOCAL}.bak"
  stayed_local
  [ "$(wc -l <"${TEST_ROOT}/notify.log")" -eq 1 ]
  grep -q "kept 1 local edit on ${HOST_ARG} in its local file" "${TEST_ROOT}/notify.log"
  [[ "${output}" == *"added 1 item(s) to permissions.allow"* ]]
  nowhere 'gh issue list'
}

@test "local mode: a missing local file is created with mode 600, and no backup is made" {
  work_host
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(jq -c . "${LOCAL}")" = '{"permissions":{"allow":["Bash(git status:*)"]}}' ]
  [ "$(mode_of "${LOCAL}")" = 600 ]
  [ ! -e "${LOCAL}.bak" ]
}

@test "local mode: the local file keeps its mode" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  chmod 644 "${LOCAL}"
  make_live '.model = "sonnet"'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(jq -cS . "${LOCAL}")" = '{"localOnly":"x","model":"sonnet"}' ]
  [ "$(mode_of "${LOCAL}")" = 644 ]
}

@test "local mode: other keys of the local file, autoMode arrays too, change only where D does" {
  work_host
  printf '{"autoMode": {"environment": ["note a", "note b"], "allow": ["note c"]}, "z": {"k": [1, 2]}}\n' >"${LOCAL}"
  make_live '.permissions.allow += ["Bash(git status:*)"] | .autoMode.environment += ["note new"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(jq -c '.autoMode' "${LOCAL}")" = '{"environment":["note a","note b","note new"],"allow":["note c"]}' ]
  [ "$(jq -c '.z' "${LOCAL}")" = '{"k":[1,2]}' ]
  [ "$(jq -c '.permissions.allow' "${LOCAL}")" = '["Bash(git status:*)"]' ]
}

@test "local mode: a policy key is refused: exit 3, the local file untouched" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  save_local
  make_live '.hooks = {"Stop": []}'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"hooks"*"policy-key"* ]]
  untouched
  stayed_local
}

@test "local mode: a secret-shaped string is refused: exit 3, the local file untouched" {
  local secret
  secret="$(rand_hex 6)"
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  save_local
  make_live ".permissions.allow += [\"Bash(curl --token ${secret}:*)\"]"
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"secret-shaped-string"* ]]
  untouched
  stayed_local
  nowhere "${secret}"
}

@test "local mode: removing a rule base.json supplies is refused: exit 3, the local file untouched" {
  work_host
  printf '{"permissions": {"allow": ["Bash(local:*)"]}}\n' >"${LOCAL}"
  save_local
  make_live '.permissions.allow -= ["Bash(ls:*)"]'
  run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"removes something"*"permissions"* ]]
  untouched
  nowhere 'Bash(ls'
}

@test "local mode: removing a rule only the local file supplies drops it, and an emptied parent goes" {
  work_host
  printf '{"permissions": {"allow": ["Bash(local:*)"]}, "localOnly": "x"}\n' >"${LOCAL}"
  make_live '.permissions.allow -= ["Bash(local:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(jq -c . "${LOCAL}")" = '{"localOnly":"x"}' ]
  [[ "${output}" == *"removed 1 item from permissions.allow"* ]]
}

@test "local mode: a build with the new local file that does not hold D is refused, the file untouched" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  save_local
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  # The real build, except that its dry run reports drift.
  cat >"${TEST_ROOT}/bin/build" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [[ "\${a}" != --dry-run ]] || exit 2; done
exec bash "${BUILD}" "\$@"
STUB
  HARVEST_BUILD_BIN="${TEST_ROOT}/bin/build" run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"does not hold every local change"* ]]
  cmp -s "${TEST_ROOT}/local.orig" "${LOCAL}"
  [ -z "$(find "${TEST_ROOT}" -maxdepth 1 -name '.user-settings.local.*')" ]
}

@test "local mode: a written file that is not the old file plus D is refused, the file untouched" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  save_local
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  # A cp that plants an extra key in the temp file (the backup copy is real).
  cat >"${TEST_ROOT}/bin/badcp" <<'STUB'
#!/usr/bin/env bash
dst="${*: -1}"
src="${*: -2:1}"
if [[ "${dst}" == *.bak ]]; then exec "${TEST_ROOT}/bin/cp" "$@"; fi
jq '. + {"planted": true}' "${src}" >"${dst}"
STUB
  chmod +x "${TEST_ROOT}/bin/badcp"
  HARVEST_CP_BIN="${TEST_ROOT}/bin/badcp" run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"not the old file plus the local changes"* ]]
  cmp -s "${TEST_ROOT}/local.orig" "${LOCAL}"
  [ -z "$(find "${TEST_ROOT}" -maxdepth 1 -name '.user-settings.local.*')" ]
}

@test "local mode: a local file edited while the harvest runs is left as it is: exit 3" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  # The real build, except that its dry run (the last step before mv) also edits the local file.
  cat >"${TEST_ROOT}/bin/build" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\${a}" != --dry-run ]] || printf '{"localOnly": "edited"}\\n' >"${LOCAL}"
done
exec bash "${BUILD}" "\$@"
STUB
  HARVEST_BUILD_BIN="${TEST_ROOT}/bin/build" run harvest
  [ "${status}" -eq 3 ]
  [[ "${output}" == *"changed while the harvest ran"* ]]
  [ "$(jq -c . "${LOCAL}")" = '{"localOnly":"edited"}' ]
  [ -z "$(find "${TEST_ROOT}" -maxdepth 1 -name '.user-settings.local.*')" ]
}

@test "local mode: --dry-run says what it would write and writes nothing" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  save_local
  make_live '.permissions.allow += ["Bash(gh issue list:*)"]'
  run harvest --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run: would write 1 local edit(s)"* ]]
  untouched
  stayed_local
  [ ! -s "${TEST_ROOT}/notify.log" ]
  nowhere 'gh issue list'
}

@test "local mode: two separate edits notify twice; a repeat run writes and notifies nothing" {
  work_host
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  run harvest
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already holds every local change"* ]]
  [ "$(wc -l <"${TEST_ROOT}/notify.log")" -eq 1 ]
  # The notice carries the time in seconds: wait so the second edit's notice differs.
  sleep 1
  make_live '.permissions.allow += ["Bash(git diff:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  [ "$(wc -l <"${TEST_ROOT}/notify.log")" -eq 2 ]
}

@test "a personal Mac still takes the repo path, and its local file is not written" {
  make_live '.permissions.allow += ["Bash(git status:*)"]'
  run harvest
  [ "${status}" -eq 0 ]
  pushed
  [ ! -e "${LOCAL}" ]
}

# The deploy's own build of the live file, as install.sh runs it.
real_build() {
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" MACHINE_SETTINGS_HOST="${HOST_ARG}" bash "${BUILD}" \
    --src "${SRC}" --out "${LIVE}" --report "${TEST_ROOT}/e2e.diff" --local "${LOCAL}" --host-optional "$@"
}

@test "local mode end to end: main moved, so the real build resolves the drift and live equals .built" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  make_live '.permissions.allow += ["Bash(gh issue list:*)"]'
  # After the last build, base gains a rule: the new build differs from live, so only a three-way merge clears it.
  write_base <<'JSON'
{"model": "opus", "theme": "dark", "permissions": {"allow": ["Bash(ls:*)", "Bash(pwd)"]}, "enabledPlugins": {"a@m": true}}
JSON
  run real_build --dry-run
  [ "${status}" -eq 2 ]
  run harvest
  [ "${status}" -eq 0 ]
  run real_build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"drift resolved"* ]]
  [ "$(jq -cS . "${LIVE}")" = "$(jq -cS . "${LIVE}.built")" ]
  jq -e '.permissions.allow | index(["Bash(gh issue list:*)"]) and index(["Bash(pwd)"])' "${LIVE}" >/dev/null
}

@test "local mode end to end: main did not move, so the real build finds live equal to it and records .built" {
  work_host
  printf '{"localOnly": "x"}\n' >"${LOCAL}"
  make_live '.permissions.allow += ["Bash(gh issue list:*)"]'
  run real_build --dry-run
  [ "${status}" -eq 2 ]
  run harvest
  [ "${status}" -eq 0 ]
  run real_build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already matches"* ]]
  [ "$(jq -cS . "${LIVE}")" = "$(jq -cS . "${LIVE}.built")" ]
  [ ! -e "${TEST_ROOT}/e2e.diff" ]
}
