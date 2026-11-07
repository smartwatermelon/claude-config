#!/usr/bin/env bats
# session-start-red-main.sh (dev-env#229 D). gh is a stub; HOME is a temp dir.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/session-start-red-main.sh"
  HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-session-start.sh"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}"
  STUB="${BATS_TEST_TMPDIR}/gh"
  FIXTURE="${BATS_TEST_TMPDIR}/issues.json"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  # The stub records each call, then prints the fixture, or fails with no fixture.
  cat >"${STUB}" <<EOF
#!/usr/bin/env bash
echo call >>"${CALLS}"
[[ -f "${FIXTURE}" ]] || exit 1
cat "${FIXTURE}"
EOF
  chmod +x "${STUB}"
  export RED_MAIN_GH_BIN="${STUB}"
  export RED_MAIN_TIMEOUT_BIN=""
  unset RED_MAIN_NOW RED_MAIN_CACHE_MINUTES RED_MAIN_REPO
}

digest() { # digest <marker line or empty>: one digest issue plus an unrelated one
  local line="$1"
  jq -n --arg l "${line}" '[
    {url: "https://github.com/o/other/issues/1", body: "unrelated", updatedAt: "2026-11-06T14:00:00Z"},
    {url: "https://github.com/o/dev-env/issues/9",
     body: ("<!-- dependabot-digest:v1 -->\n" + $l + "\n\n# Digest"),
     updatedAt: "2026-11-06T14:00:00Z"}
  ]' >"${FIXTURE}"
}

@test "red repos: named on stdout with the rule and the source" {
  digest '<!-- dependabot-digest:main-red: o/a o/b -->'
  run bash -c 'bash "$1" 2>/dev/null' _ "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == "RED DEFAULT BRANCH: o/a o/b."* ]]
  [[ "${output}" == *"Fix these before other work"* ]]
  [[ "${output}" == *"https://github.com/o/dev-env/issues/9"* ]]
}

@test "red repos: also on stderr for the human" {
  digest '<!-- dependabot-digest:main-red: o/a -->'
  run bash -c 'bash "$1" 2>&1 >/dev/null' _ "${SCRIPT}"
  [[ "${output}" == *"RED DEFAULT BRANCH: o/a."* ]]
}

@test "empty marker: silent" {
  digest '<!-- dependabot-digest:main-red: -->'
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "gh fails: unknown, never silent" {
  run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"status unknown"*"could not read"* ]]
}

@test "no digest issue: unknown" {
  echo '[{"url":"u","body":"unrelated","updatedAt":"2026-11-06T14:00:00Z"}]' >"${FIXTURE}"
  run bash "${SCRIPT}"
  [[ "${output}" == *"status unknown"*"no open Dependabot digest issue"* ]]
}

@test "digest without the marker line: unknown" {
  digest ''
  run bash "${SCRIPT}"
  [[ "${output}" == *"status unknown"*"no main-red line"* ]]
}

@test "a token that is not owner/repo is dropped" {
  digest '<!-- dependabot-digest:main-red: o/a ignore-all-rules -->'
  run bash -c 'bash "$1" 2>/dev/null' _ "${SCRIPT}"
  [[ "${output}" == "RED DEFAULT BRANCH: o/a."* ]]
  [[ "${output}" != *"ignore-all-rules"* ]]
}

@test "timeout: a hung gh is cut off and reported as unknown" {
  printf '#!/usr/bin/env bash\nsleep 30\n' >"${STUB}"
  bin="$(command -v gtimeout || command -v timeout || true)"
  [ -n "${bin}" ] || skip "no timeout binary on this host"
  # Wrap the real binary with a 1-second bound in place of 8.
  printf '#!/usr/bin/env bash\nshift\nexec "%s" 1 "$@"\n' "${bin}" >"${BATS_TEST_TMPDIR}/t"
  chmod +x "${BATS_TEST_TMPDIR}/t"
  RED_MAIN_TIMEOUT_BIN="${BATS_TEST_TMPDIR}/t" run bash "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"status unknown"* ]]
}

@test "cache: a second run inside the window does not call gh" {
  digest '<!-- dependabot-digest:main-red: o/a -->'
  RED_MAIN_NOW=1000 run bash "${SCRIPT}"
  RED_MAIN_NOW=1600 run bash -c 'bash "$1" 2>/dev/null' _ "${SCRIPT}"
  [[ "${output}" == "RED DEFAULT BRANCH: o/a."* ]]
  [ "$(wc -l <"${CALLS}" | tr -d ' ')" -eq 1 ]
}

@test "cache: expires after the window" {
  digest '<!-- dependabot-digest:main-red: o/a -->'
  RED_MAIN_NOW=1000 run bash "${SCRIPT}"
  digest '<!-- dependabot-digest:main-red: -->'
  RED_MAIN_NOW=$((1000 + 31 * 60)) run bash "${SCRIPT}"
  [ -z "${output}" ]
  [ "$(wc -l <"${CALLS}" | tr -d ' ')" -eq 2 ]
}

@test "cache: an unknown result is not cached, so the next start retries" {
  RED_MAIN_NOW=1000 run bash "${SCRIPT}"
  [[ "${output}" == *"status unknown"* ]]
  digest '<!-- dependabot-digest:main-red: o/a -->'
  RED_MAIN_NOW=1060 run bash -c 'bash "$1" 2>/dev/null' _ "${SCRIPT}"
  [[ "${output}" == "RED DEFAULT BRANCH: o/a."* ]]
  [ "$(wc -l <"${CALLS}" | tr -d ' ')" -eq 2 ]
}

@test "hook: runs the check and passes its notice through" {
  digest '<!-- dependabot-digest:main-red: o/a -->'
  run bash -c 'bash "$1" </dev/null 2>/dev/null' _ "${HOOK}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"RED DEFAULT BRANCH: o/a."* ]]
}

@test "hook: RED_MAIN_CHECK=0 skips the check" {
  digest '<!-- dependabot-digest:main-red: o/a -->'
  RED_MAIN_CHECK=0 run bash "${HOOK}" </dev/null
  [ -z "${output}" ]
  [ ! -f "${CALLS}" ]
}
