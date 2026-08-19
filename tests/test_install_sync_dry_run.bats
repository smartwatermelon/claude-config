#!/usr/bin/env bats
# Tests for the `--sync --dry-run` summary in install.sh.
#
# Why this exists: in dry-run mode both _ensure_symlink() and repair_symlinks()
# return early WITHOUT appending to installed[], so the sync-mode exit block
# saw ${#installed[@]} == 0 and printed "Sync complete — deployed tree already
# matches repo" even when it had just printed a screenful of [DRY] lines
# describing links it would create. A user previewing changes got an actively
# misleading summary (claude-config#344).
#
# The fix maintains a parallel would_install[] array populated on the dry-run
# paths, and the sync-mode exit block reports from it when DRY_RUN is true.
#
# These tests run install.sh against a THROWAWAY repo and a THROWAWAY HOME so
# they never read or write the developer's real ~/.claude. install.sh derives
# REPO_DIR from ${BASH_SOURCE[0]} and DEPLOY_DIR from ${HOME}, so copying the
# script into a temp repo and overriding HOME is sufficient isolation.
#
# Run: bats ~/.claude/tests/test_install_sync_dry_run.bats

setup() {
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST

  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  export FAKE_REPO FAKE_HOME
  mkdir -p "${FAKE_REPO}" "${FAKE_HOME}"

  # A minimal git repo with a couple of tracked files. install.sh enumerates
  # tracked files via `git ls-files`, so they must actually be committed.
  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  # install.sh refuses to run unless these canary files are present, so the
  # fixture must supply all three (settings.json, CLAUDE.md, hooks/run-review.sh).
  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md hooks/run-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

# Helper: run install.sh in --sync --dry-run against the throwaway HOME.
run_sync_dry_run() {
  HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" --sync --dry-run 2>&1
}

@test "dry run with pending work does NOT claim the tree already matches" {
  run run_sync_dry_run
  # Nothing is deployed yet, so there is definitely pending work.
  [[ "${output}" != *"already matches repo"* ]]
}

@test "dry run with pending work reports a 'would create N item(s)' count" {
  run run_sync_dry_run
  [[ "${output}" =~ would\ create\ [1-9][0-9]*\ item\(s\) ]]
}

@test "dry run lists the items it would create" {
  run run_sync_dry_run
  [[ "${output}" == *"Sync would create:"* ]]
  [[ "${output}" == *"symlink:${FAKE_HOME}/.claude/settings.json"* ]]
}

@test "dry run makes no changes to the deploy dir" {
  run run_sync_dry_run
  [[ ! -e "${FAKE_HOME}/.claude/settings.json" ]]
}

@test "dry run with nothing pending still reports the tree already matches" {
  # Pre-create correct symlinks for every tracked file so _ensure_symlink
  # takes its "already correct" _skip path and would_install[] stays empty.
  mkdir -p "${FAKE_HOME}/.claude"
  local file
  while IFS= read -r file; do
    mkdir -p "$(dirname "${FAKE_HOME}/.claude/${file}")"
    ln -s "${FAKE_REPO}/${file}" "${FAKE_HOME}/.claude/${file}"
  done < <(git -C "${FAKE_REPO}" ls-files)

  run run_sync_dry_run
  [[ "${output}" == *"already matches repo"* ]]
  [[ "${output}" != *"would create"* ]]
}
