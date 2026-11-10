#!/usr/bin/env bats
# install.sh section 7c: ~/.claude/settings.json is a generated file, built
# from user-settings/ by scripts/build-machine-settings.sh (claude-config#842).
#
# Before #842 it was a symlink into the repo, so every /model, /config,
# /permissions or iTerm2 write dirtied the deploy clone and stopped the deploy.
# Now the deploy clone's --sync builds it; a local edit is kept and reported,
# never a deploy failure.
#
# Isolation: a throwaway HOME under BATS_TEST_TMPDIR holds the clone, the
# working checkout and ~/.claude. The build's mv and rm are stubs that refuse
# any path outside the test dir. Global and system git config are off, so no
# global hook (post-checkout scaffolds) writes into the fixture clones.
#
# Run: bats tests/test_install_user_settings.bats

ROOT="${BATS_TEST_DIRNAME:?}/.."

setup() {
  [[ "$(uname -s)" == "Darwin" ]] || skip "install.sh is macOS-only"
  TEST_ROOT="$(cd "${BATS_TEST_TMPDIR:?}" && pwd -P)"
  FAKE_HOME="${TEST_ROOT}/home"
  DEPLOY="${FAKE_HOME}/.claude"
  CLONE="${FAKE_HOME}/.local/share/claude-config"
  DEV="${FAKE_HOME}/Developer/claude-config"
  OUT="${DEPLOY}/settings.json"
  REPORT="${FAKE_HOME}/.local/state/claude-config/user-settings.drift.diff"
  STUB_LOG="${TEST_ROOT}/stub.log"
  mkdir -p "${DEPLOY}" "${TEST_ROOT}/tmp" "${TEST_ROOT}/bin"
  : >"${STUB_LOG}"
  make_guarded_stub mv
  make_guarded_stub rm
  export MACHINE_SETTINGS_MV_BIN="${TEST_ROOT}/bin/mv"
  export MACHINE_SETTINGS_RM_BIN="${TEST_ROOT}/bin/rm"
  export MACHINE_SETTINGS_HOST="TESTHOST"
  export MACHINE_SETTINGS_TMPDIR="/var/folders/xx/test/T/"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export STUB_LOG TEST_ROOT
}

# A stub that logs its arguments, refuses any path outside TEST_ROOT, then
# runs the real command. Same as tests/test_build_machine_settings.bats.
make_guarded_stub() {
  local name="$1" real
  real="$(command -v "${name}")"
  {
    cat <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"${STUB_LOG}"
for a in "$@"; do
  case "${a}" in
    -*) ;;
    "${TEST_ROOT}"/*) ;;
    *)
      echo "stub: refusing a path outside the test dir: ${a}" >&2
      exit 99
      ;;
  esac
done
STUB
    printf 'exec %q "$@"\n' "${real}"
  } >"${TEST_ROOT}/bin/${name}"
  chmod +x "${TEST_ROOT}/bin/${name}"
}

commit_all() {
  local dir="$1" msg="$2"
  git -C "${dir}" add -A
  git -c user.name=T -c user.email=t@t -c commit.gpgSign=false -C "${dir}" commit -q -m "${msg}"
}

# The new layout: canaries, the build script, user-settings/ and machine-settings/.
new_layout() {
  local dir="$1"
  mkdir -p "${dir}/hooks" "${dir}/scripts" "${dir}/user-settings/hosts" "${dir}/machine-settings/hosts"
  cp "${ROOT}/install.sh" "${dir}/install.sh"
  cp "${ROOT}/scripts/build-machine-settings.sh" "${dir}/scripts/build-machine-settings.sh"
  chmod +x "${dir}/scripts/build-machine-settings.sh"
  printf '# test\n' >"${dir}/CLAUDE.md"
  printf '#!/usr/bin/env bash\n' >"${dir}/hooks/run-review.sh"
  chmod +x "${dir}/hooks/run-review.sh"
  printf '{"model": "base-model", "autoMode": {"allow": ["u0"]}}\n' >"${dir}/user-settings/base.json"
  printf '{"autoMode": {"allow": ["u-host"]}}\n' >"${dir}/user-settings/hosts/TESTHOST.json"
  printf '{"env": {"A": "1"}}\n' >"${dir}/machine-settings/base.json"
  printf '{}\n' >"${dir}/machine-settings/hosts/TESTHOST.json"
}

make_repo() {
  local dir="$1"
  mkdir -p "${dir}"
  git init -q "${dir}"
  new_layout "${dir}"
  commit_all "${dir}" "initial"
}

run_install() {
  local repo="$1"
  shift
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" bash "${repo}/install.sh" "$@" 2>&1
}

expected_user() {
  jq -S -n '{"model": "base-model", "autoMode": {"allow": ["u0", "u-host"]}}'
}

# --- the generated file -------------------------------------------------------

@test "deploy clone --sync replaces the settings.json symlink with a generated file" {
  make_repo "${CLONE}"
  printf '{"a": 1}\n' >"${TEST_ROOT}/target.json"
  ln -s "${TEST_ROOT}/target.json" "${OUT}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ -f "${OUT}" && ! -L "${OUT}" ]]
  [ "$(jq -S . "${OUT}")" = "$(expected_user)" ]
  # The link target is untouched, and the replaced content is backed up.
  [ "$(cat "${TEST_ROOT}/target.json")" = '{"a": 1}' ]
  run find "${DEPLOY}" -maxdepth 1 -name 'settings.json.bak-*-pre-build'
  [ -n "${output}" ]
}

@test "a local edit to ~/.claude/settings.json is kept and the sync still succeeds" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  jq -c '. + {"theme": "local"}' "${OUT}" >"${TEST_ROOT}/edit.json"
  cat "${TEST_ROOT}/edit.json" >"${OUT}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Local changes in ${OUT} kept"* ]]
  [[ "${output}" == *"Report: ${REPORT}"* ]]
  [[ "${output}" != *"! user-settings"* ]]
  [ "$(jq -r .theme "${OUT}")" = "local" ]
  [[ -f "${REPORT}" ]]
}

@test "--dev does not build user settings" {
  make_repo "${CLONE}"
  make_repo "${DEV}"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Not the deploy clone"* ]]
  [[ ! -e "${OUT}" && ! -L "${OUT}" ]]
}

@test "--sync --dry-run on the clone writes no settings.json" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run: would write ${OUT}"* ]]
  [[ ! -e "${OUT}" && ! -L "${OUT}" ]]
}

@test "settings.json is no longer linked into ~/.claude" {
  make_repo "${CLONE}"
  # Even a tracked root settings.json (an old branch, a revert) is not linked.
  printf '{"tracked": true}\n' >"${CLONE}/settings.json"
  commit_all "${CLONE}" "root settings.json"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ ! -L "${OUT}" ]]
  [ "$(jq -r '.tracked // "absent"' "${OUT}")" = "absent" ]
  [[ ! -e "${DEPLOY}/user-settings" && ! -L "${DEPLOY}/user-settings" ]]
}

@test "the user-settings local overlay is merged; a stray ~/.claude/settings.local.json is not" {
  make_repo "${CLONE}"
  printf '{"stray": true}\n' >"${DEPLOY}/settings.local.json"
  mkdir -p "${FAKE_HOME}/.config/claude-code"
  printf '{"mine": true}\n' >"${FAKE_HOME}/.config/claude-code/user-settings.local.json"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [ "$(jq -r '.stray // "absent"' "${OUT}")" = "absent" ]
  [ "$(jq -r '.mine' "${OUT}")" = "true" ]
  [ "$(cat "${DEPLOY}/settings.local.json")" = '{"stray": true}' ]
}

@test "the ~/.claude audit and prune leave settings.json.built and .bak-*-pre-build alone" {
  make_repo "${CLONE}"
  mkdir -p "${CLONE}/scripts"
  cp "${ROOT}/scripts/known-runtime.txt" "${CLONE}/scripts/known-runtime.txt"
  commit_all "${CLONE}" "known-runtime"
  printf '{"a": 1}\n' >"${TEST_ROOT}/target.json"
  ln -s "${TEST_ROOT}/target.json" "${OUT}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  local bak
  bak="$(find "${DEPLOY}" -maxdepth 1 -name 'settings.json.bak-*-pre-build')"
  [[ -f "${OUT}.built" && -n "${bak}" ]]
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  HOME="${FAKE_HOME}" run bash "${ROOT}/scripts/update-tools.sh"
  [ "${status}" -eq 0 ]
  # The audit lists each unknown entry as "  <path>" at the end of a line.
  local line
  while IFS= read -r line; do
    [[ "${line}" != *"  ${OUT}" && "${line}" != *"  ${OUT}.built" ]] || {
      echo "audit flags: ${line}" >&2
      return 1
    }
  done <<<"${output}"
  [[ -f "${OUT}" && ! -L "${OUT}" && -f "${OUT}.built" && -f "${bak}" ]]
}

# --- first deploy over the old symlink layout ---------------------------------

# The old layout: settings.json tracked at the root behind the iTerm2 clean
# filter, which every clone had configured with required=true (install.sh
# section 8), and ~/.claude/settings.json a link into the clone.
old_origin() {
  ORIGIN="${TEST_ROOT}/origin"
  mkdir -p "${ORIGIN}"
  git init -q "${ORIGIN}"
  new_layout "${ORIGIN}"
  "${MACHINE_SETTINGS_MV_BIN}" "${ORIGIN}/user-settings/base.json" "${ORIGIN}/settings.json"
  "${MACHINE_SETTINGS_RM_BIN}" "${ORIGIN}/user-settings/hosts/TESTHOST.json"
  printf 'settings.json filter=iterm-home\n' >"${ORIGIN}/.gitattributes"
  printf '#!/usr/bin/env bash\ncat\n' >"${ORIGIN}/scripts/normalize-iterm-home.sh"
  chmod +x "${ORIGIN}/scripts/normalize-iterm-home.sh"
  commit_all "${ORIGIN}" "old layout"
  git clone -q "${ORIGIN}" "${CLONE}"
  git -C "${CLONE}" config filter.iterm-home.clean "${CLONE}/scripts/normalize-iterm-home.sh"
  git -C "${CLONE}" config filter.iterm-home.smudge cat
  git -C "${CLONE}" config filter.iterm-home.required true
  ln -s "${CLONE}/settings.json" "${OUT}"
}

# The PR 3 change on origin: settings.json moves to user-settings/base.json; the filter goes.
advance_origin() {
  git -C "${ORIGIN}" mv settings.json user-settings/base.json
  git -C "${ORIGIN}" rm -q .gitattributes scripts/normalize-iterm-home.sh
  new_layout "${ORIGIN}"
  commit_all "${ORIGIN}" "new layout"
}

# What claude-config-deploy.sh does: fetch, fast-forward.
pull_clone() {
  git -C "${CLONE}" fetch -q origin
  git -C "${CLONE}" merge --ff-only --quiet origin/HEAD
}

@test "first deploy: the dangling settings.json link becomes a generated file, the clone stays clean" {
  old_origin
  advance_origin
  run pull_clone
  [ "${status}" -eq 0 ]
  [[ -L "${OUT}" && ! -e "${OUT}" ]] # dangles into the clone until the sync
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ -f "${OUT}" && ! -L "${OUT}" ]]
  [ "$(jq -S . "${OUT}")" = "$(expected_user)" ]
  [[ ! -e "${CLONE}/settings.json" ]]
  run git -C "${CLONE}" status --porcelain
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "first deploy: a failed user-settings build after the prune fails the sync and says the file is missing" {
  old_origin
  advance_origin
  printf '{not json\n' >"${ORIGIN}/user-settings/base.json"
  commit_all "${ORIGIN}" "broken user settings"
  run pull_clone
  [ "${status}" -eq 0 ]
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Removed stale symlink: ${OUT}"* ]]
  [[ "${output}" == *"User settings build failed; ${OUT} is missing"* ]]
  [[ "${output}" == *"! user-settings"* ]]
  [[ ! -e "${OUT}" && ! -L "${OUT}" ]]
  run git -C "${CLONE}" status --porcelain
  [ -z "${output}" ]
}

@test "a failed user-settings build keeps the previous file and fails the sync" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  cp "${OUT}" "${TEST_ROOT}/before.json"
  printf '{"model": "%s{NOPE}"}\n' '$' >"${CLONE}/user-settings/base.json"
  commit_all "${CLONE}" "bad placeholder"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"User settings build failed; the previous ${OUT} is unchanged"* ]]
  [[ "${output}" == *"! user-settings"* ]]
  cmp -s "${OUT}" "${TEST_ROOT}/before.json"
}
