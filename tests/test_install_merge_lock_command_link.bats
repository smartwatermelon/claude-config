#!/usr/bin/env bats
# Tests for install.sh's ~/Applications/merge-lock.command launcher link.
#
# install.sh links ${HOME}/Applications/merge-lock.command to the DEPLOYED copy
# at ${HOME}/.claude/hooks/merge-lock.command, through the same _link_command
# helper as ~/.local/bin/claude-incognito
# (see test_install_claude_incognito_link.bats).
#
# Isolation: install.sh derives REPO_DIR from ${BASH_SOURCE[0]} and DEPLOY_DIR
# from ${HOME}, so a throwaway repo plus a throwaway HOME is sufficient.
#
# Run: bats ~/Developer/claude-config/tests/test_install_merge_lock_command_link.bats

setup() {
  # install.sh exits at its Darwin check on any other OS.
  [[ "$(uname -s)" == "Darwin" ]] || skip "install.sh is macOS-only"
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  mkdir -p "${FAKE_REPO}" "${FAKE_HOME}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  # Canary files install.sh requires, plus a stub merge-lock.command.
  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/merge-lock.command"
  chmod +x "${FAKE_REPO}/hooks/run-review.sh" "${FAKE_REPO}/hooks/merge-lock.command"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md \
    hooks/run-review.sh hooks/merge-lock.command
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"

  LINK="${FAKE_HOME}/Applications/merge-lock.command"
  WANT="${FAKE_HOME}/.claude/hooks/merge-lock.command"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

run_install() {
  HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" "$@" 2>&1
}

@test "--sync creates ~/Applications/merge-lock.command pointing into ~/.claude" {
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ -L "${LINK}" ]]
  [[ "$(readlink "${LINK}")" == "${WANT}" ]]
  # The chain resolves: ~/Applications -> ~/.claude/hooks -> repo.
  [[ -x "${LINK}" ]]
}

@test "rerun is idempotent: link skipped, not reinstalled" {
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Symlink already correct: ${LINK}"* ]]
  [[ "${output}" == *"already matches repo"* ]]
}

@test "dry run creates nothing and reports the link as pending" {
  run run_install --sync --dry-run
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${FAKE_HOME}/Applications" ]]
  [[ "${output}" == *"symlink:${LINK}"* ]]
}

@test "a hand-made link straight to the repo is repointed at ~/.claude" {
  mkdir -p "${FAKE_HOME}/Applications"
  ln -s "${FAKE_REPO}/hooks/merge-lock.command" "${LINK}"
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ "$(readlink "${LINK}")" == "${WANT}" ]]
}

@test "untracked launcher is skipped (link would dangle)" {
  git -C "${FAKE_REPO}" rm -q --cached hooks/merge-lock.command
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "untrack"
  run run_install --sync
  [[ "${status}" -eq 0 ]]
  [[ ! -L "${LINK}" ]]
}

@test "non-executable launcher is reported, not linked" {
  chmod -x "${FAKE_REPO}/hooks/merge-lock.command"
  run run_install --sync
  [[ "${output}" == *"Not executable: ${FAKE_REPO}/hooks/merge-lock.command"* ]]
  [[ ! -L "${LINK}" ]]
}
