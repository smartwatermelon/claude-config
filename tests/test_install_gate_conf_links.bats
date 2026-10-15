#!/usr/bin/env bats
# install.sh --sync links the gate's root config files into ~/.claude:
# gate-rules.conf (read by gate-route.sh) and copy-paths.conf (read by
# gate-copy.py). Both come from the main symlink loop over tracked files, so
# this guards against a future _is_excluded rule that skips them. The write
# hooks guard the deployed paths, so the link is what makes them agent-unwritable.
#
# Isolation: a throwaway repo plus a throwaway HOME, as in
# test_install_merge_lock_command_link.bats.

setup() {
  [[ "$(uname -s)" == "Darwin" ]] || skip "install.sh is macOS-only"
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  mkdir -p "${FAKE_REPO}" "${FAKE_HOME}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  cp "${BATS_TEST_DIRNAME}/../gate-rules.conf" "${FAKE_REPO}/gate-rules.conf"
  cp "${BATS_TEST_DIRNAME}/../copy-paths.conf" "${FAKE_REPO}/copy-paths.conf"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  mkdir -p "${FAKE_REPO}/hooks"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  chmod +x "${FAKE_REPO}/hooks/run-review.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md hooks/run-review.sh \
    gate-rules.conf copy-paths.conf
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

@test "--sync links copy-paths.conf and gate-rules.conf into ~/.claude" {
  run env HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" --sync
  [[ "${status}" -eq 0 ]]
  for f in copy-paths.conf gate-rules.conf; do
    [[ -L "${FAKE_HOME}/.claude/${f}" ]]
    [[ "$(readlink "${FAKE_HOME}/.claude/${f}")" == "${FAKE_REPO}/${f}" ]]
  done
}
