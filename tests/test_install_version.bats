#!/usr/bin/env bats
# Tests for the version lines in install.sh (smartwatermelon/dev-env#72).
#
# install.sh prints "claude-config: installing <version>" before it acts and,
# from an EXIT trap, one closing line for whichever exit path it took. Only a
# successful real run records the version under $XDG_STATE_HOME.
#
# Same isolation as test_install_sync_dry_run.bats: a throwaway repo and HOME.
#
# Run: bats ~/.claude/tests/test_install_version.bats

setup() {
  [[ "${OSTYPE}" == darwin* ]] || skip "install.sh is macOS-only"
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  FAKE_STATE="${TMPDIR_TEST}/state"
  mkdir -p "${FAKE_REPO}" "${FAKE_HOME}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"
  git -C "${FAKE_REPO}" config tag.gpgSign false
  git -C "${FAKE_REPO}" config commit.gpgSign false

  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md hooks/run-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"
  git -C "${FAKE_REPO}" tag v1.2.3
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

run_install() {
  HOME="${FAKE_HOME}" XDG_STATE_HOME="${FAKE_STATE}" \
    bash "${FAKE_REPO}/install.sh" "$@" 2>&1
}

@test "announces the tagged version before acting" {
  run run_install --sync --dry-run
  [[ "${output}" == *"claude-config: installing v1.2.3"* ]]
}

@test "a dry run says nothing was installed and records nothing" {
  run run_install --sync --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"claude-config: dry run of v1.2.3; nothing installed"* ]]
  [[ ! -e "${FAKE_STATE}/claude-config/version" ]]
}

@test "a successful install reports and records the installed version" {
  # A full --sync cannot pass its smoke tests in this fixture, so run only
  # the Version block, cut from install.sh by its markers, and exit 0.
  sed -n '/^# ── Version ──/,/^trap _report_version EXIT$/p' \
    "${FAKE_REPO}/install.sh" >"${TMPDIR_TEST}/block.sh"
  grep -q '^trap _report_version EXIT$' "${TMPDIR_TEST}/block.sh"
  cat >"${TMPDIR_TEST}/runner.sh" <<'EOF'
_info() { echo "$*"; }
_ok() { echo "$*"; }
_warn() { echo "$*"; }
_err() { echo "$*"; }
# shellcheck source=/dev/null
source "$1"
EOF
  run env REPO_DIR="${FAKE_REPO}" DRY_RUN=false REPAIR_ONLY=false \
    HOME="${FAKE_HOME}" XDG_STATE_HOME="${FAKE_STATE}" \
    bash "${TMPDIR_TEST}/runner.sh" "${TMPDIR_TEST}/block.sh"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"claude-config: installed v1.2.3"* ]]
  run cat "${FAKE_STATE}/claude-config/version"
  [ "${output}" = "v1.2.3" ]
}

@test "a repair run does not claim an install or record a version" {
  run run_install --repair
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"claude-config: repaired links for v1.2.3; no new files installed"* ]]
  [[ "${output}" != *"claude-config: installed"* ]]
  [[ ! -e "${FAKE_STATE}/claude-config/version" ]]
}

@test "commits past the tag and uncommitted changes show in the version" {
  printf 'x\n' >"${FAKE_REPO}/extra"
  git -C "${FAKE_REPO}" add extra
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "second"
  printf '# edited\n' >>"${FAKE_REPO}/CLAUDE.md"
  run run_install --sync --dry-run
  [[ "${output}" =~ claude-config:\ installing\ v1\.2\.3-1-g[0-9a-f]+-dirty ]]
}

@test "a failed run reports the failure and records nothing" {
  # A file where the deploy dir should be fails the run after the trap is set.
  printf 'not a dir\n' >"${FAKE_HOME}/.claude"
  run run_install --sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"claude-config: install of v1.2.3 failed (exit ${status})"* ]]
  [[ ! -e "${FAKE_STATE}/claude-config/version" ]]
}
