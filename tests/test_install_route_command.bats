#!/usr/bin/env bats
# install.sh writes personify's route-command file: one line, the absolute path
# of the deployed scripts/gate-review.sh. personify's pangram_check.py runs
# `<that path> route ...` and calls Pangram only on a `pangram` route, so a
# missing or wrong file means paying for calls that do not need to happen.
#
# Isolation: a throwaway repo plus a throwaway HOME and XDG_CONFIG_HOME, as in
# test_install_gate_conf_links.bats. Nothing here touches the real home.

setup() {
  [[ "$(uname -s)" == "Darwin" ]] || skip "install.sh is macOS-only"
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_REPO="${TMPDIR_TEST}/repo"
  FAKE_HOME="${TMPDIR_TEST}/home"
  FAKE_XDG="${TMPDIR_TEST}/xdg"
  mkdir -p "${FAKE_REPO}/hooks" "${FAKE_REPO}/scripts" "${FAKE_HOME}"

  git -C "${FAKE_REPO}" init -q
  git -C "${FAKE_REPO}" config user.email "test@test.com"
  git -C "${FAKE_REPO}" config user.name "Test"

  cp "${BATS_TEST_DIRNAME}/../install.sh" "${FAKE_REPO}/install.sh"
  printf '{}\n' >"${FAKE_REPO}/settings.json"
  printf '# test\n' >"${FAKE_REPO}/CLAUDE.md"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/hooks/run-review.sh"
  printf '#!/usr/bin/env bash\n' >"${FAKE_REPO}/scripts/gate-review.sh"
  chmod +x "${FAKE_REPO}/hooks/run-review.sh" "${FAKE_REPO}/scripts/gate-review.sh"
  git -C "${FAKE_REPO}" add install.sh settings.json CLAUDE.md hooks/run-review.sh \
    scripts/gate-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "initial"

  ROUTE_FILE="${FAKE_XDG}/personify/route-command"
  WANT="${FAKE_HOME}/.claude/scripts/gate-review.sh"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

_install() {
  run env HOME="${FAKE_HOME}" XDG_CONFIG_HOME="${FAKE_XDG}" bash "${FAKE_REPO}/install.sh" "$@"
}

@test "--sync writes route-command naming the deployed gate-review.sh" {
  _install --sync
  [[ "${status}" -eq 0 ]]
  [[ -f "${ROUTE_FILE}" && ! -L "${ROUTE_FILE}" ]]
  [[ "$(cat "${ROUTE_FILE}")" == "${WANT}" ]]
  # One line, newline-terminated.
  [[ "$(wc -l <"${ROUTE_FILE}" | tr -d ' ')" == 1 ]]
  # The path it names is the deployed link, and it runs.
  [[ -x "${WANT}" ]]
}

@test "a plain install writes it too" {
  _install
  [[ "${status}" -eq 0 ]]
  [[ "$(cat "${ROUTE_FILE}")" == "${WANT}" ]]
}

@test "with no XDG_CONFIG_HOME it goes under ~/.config" {
  run env -u XDG_CONFIG_HOME HOME="${FAKE_HOME}" bash "${FAKE_REPO}/install.sh" --sync
  [[ "${status}" -eq 0 ]]
  [[ "$(cat "${FAKE_HOME}/.config/personify/route-command")" == "${WANT}" ]]
}

@test "a second run leaves it alone and says so" {
  _install --sync
  [[ "${status}" -eq 0 ]]
  _install --sync
  [[ "${status}" -eq 0 ]]
  [[ "${output}" == *"Route command already correct: ${ROUTE_FILE}"* ]]
  [[ "${output}" != *"Wrote route command"* ]]
  [[ "$(cat "${ROUTE_FILE}")" == "${WANT}" ]]
  # No temp file left beside it.
  [[ "$(find "${FAKE_XDG}/personify" -type f | wc -l | tr -d ' ')" == 1 ]]
}

@test "a stale path is rewritten" {
  mkdir -p "${FAKE_XDG}/personify"
  printf '/somewhere/else/fake.sh\n' >"${ROUTE_FILE}"
  _install --sync
  [[ "${status}" -eq 0 ]]
  [[ "$(cat "${ROUTE_FILE}")" == "${WANT}" ]]
}

@test "--sync --dry-run writes nothing and says what it would write" {
  _install --sync --dry-run
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${ROUTE_FILE}" ]]
  [[ "${output}" == *"Would write ${ROUTE_FILE}: ${WANT}"* ]]
}

@test "no tracked gate-review.sh: skipped, no file" {
  git -C "${FAKE_REPO}" rm -q scripts/gate-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_REPO}" commit -q -m "drop gate"
  _install --sync
  [[ "${status}" -eq 0 ]]
  [[ ! -e "${ROUTE_FILE}" ]]
  [[ "${output}" == *"No tracked scripts/gate-review.sh"* ]]
}
