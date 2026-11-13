#!/usr/bin/env bats
# scripts/build-machine-settings.sh and its call from install.sh (dev-env#249).
#
# The script builds ~/.config/claude-code/machine-settings.json from
# machine-settings/base.json plus machine-settings/hosts/<HOST>.json.
#
# Isolation: every case runs with a throwaway HOME and TMPDIR, an explicit
# output path under them, and stub mv/rm that refuse any path outside the
# test's temp dir. The host name and the temp-dir placeholder come from the
# MACHINE_SETTINGS_* overrides, so these cases also run on Linux CI. Only the
# install.sh cases need macOS.
#
# Run: bats tests/test_build_machine_settings.bats

SCRIPT="${BATS_TEST_DIRNAME:?}/../scripts/build-machine-settings.sh"

setup() {
  # bats removes BATS_TEST_TMPDIR itself. Physical path, so the stubs' prefix test holds.
  TEST_ROOT="$(cd "${BATS_TEST_TMPDIR:?}" && pwd -P)"
  FAKE_HOME="${TEST_ROOT}/home"
  SRC="${TEST_ROOT}/src"
  OUT="${FAKE_HOME}/.config/claude-code/machine-settings.json"
  STUB_LOG="${TEST_ROOT}/stub.log"
  mkdir -p "${FAKE_HOME}" "${SRC}/hosts" "${TEST_ROOT}/tmp" "${TEST_ROOT}/bin"
  : >"${STUB_LOG}"
  make_guarded_stub mv
  make_guarded_stub rm
  export MACHINE_SETTINGS_MV_BIN="${TEST_ROOT}/bin/mv"
  export MACHINE_SETTINGS_RM_BIN="${TEST_ROOT}/bin/rm"
  export MACHINE_SETTINGS_HOST="TESTHOST"
  export MACHINE_SETTINGS_TMPDIR="/var/folders/xx/test/T/"
  export STUB_LOG TEST_ROOT
}

# A stub that logs its arguments, refuses any path outside TEST_ROOT, then
# runs the real command. No case can reach a real mv or rm on a host path.
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

# Fixtures come from quoted heredocs on stdin, so ${HOME} and friends stay literal.
write_base() { cat >"${SRC}/base.json"; }
write_host() { cat >"${SRC}/hosts/${1:-TESTHOST}.json"; }
# The local overlay sits beside the output by default: machine-settings.local.json.
write_local() { mkdir -p "${OUT%/*}" && cat >"${OUT%.json}.local.json"; }

build() {
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" bash "${SCRIPT}" --src "${SRC}" --out "${OUT}" "$@"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

old_file() {
  mkdir -p "${OUT%/*}"
  printf '{"old": true}\n' >"${OUT}"
}

# jq -c of one path in the output, into ${output}.
out_json() { run jq -c "$1" "${OUT}"; }

# Leftover temp or backup files beside the output, into ${output}.
leftovers() { run find "${OUT%/*}" -name "$1"; }

# A hand edit to the live file: same JSON plus one key.
hand_edit() {
  jq -c '. + {"hand": "edit"}' "${OUT}" >"${TEST_ROOT}/edit.json"
  cat "${TEST_ROOT}/edit.json" >"${OUT}"
}

# --- merge ------------------------------------------------------------------

@test "merge: objects merge deep and a host scalar replaces the base's" {
  write_base <<'JSON'
{"a": {"x": 1, "y": {"p": "base"}}, "b": "base", "c": true}
JSON
  write_host <<'JSON'
{"a": {"y": {"q": "host"}, "z": 3}, "b": "host"}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = '{"x":1,"y":{"p":"base","q":"host"},"z":3}' ]
  out_json '.b'
  [ "${output}" = '"host"' ]
  out_json '.c'
  [ "${output}" = "true" ]
}

@test "merge: host arrays append to base arrays, base entries first" {
  write_base <<'JSON'
{"autoMode": {"allow": ["d0", "b1"], "soft_deny": ["d0"]}}
JSON
  write_host <<'JSON'
{"autoMode": {"allow": ["h1", "h2"]}, "sandbox": {"x": ["s"]}}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.autoMode.allow'
  [ "${output}" = '["d0","b1","h1","h2"]' ]
  out_json '.autoMode.soft_deny'
  [ "${output}" = '["d0"]' ]
  out_json '.sandbox.x'
  [ "${output}" = '["s"]' ]
}

@test "merge: an object in one file and an array in the other fails and keeps the old file" {
  old_file
  write_base <<<'{"a": {"x": 1}}'
  write_host <<<'{"a": ["x"]}'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"type clash at a"* ]]
  grep -q '"old": true' "${OUT}"
}

# --- placeholders -------------------------------------------------------------

@test "placeholder: HOME is the home directory" {
  write_base <<<'{}'
  write_host <<'JSON'
{"hooks": {"cmd": "${HOME}/.config/hook.sh"}, "list": ["${HOME}/x *"]}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.hooks.cmd'
  [ "${output}" = "\"${FAKE_HOME}/.config/hook.sh\"" ]
  out_json '.list[0]'
  [ "${output}" = "\"${FAKE_HOME}/x *\"" ]
}

@test "placeholder: TMPDIR is the per-user temp dir without its trailing slash" {
  write_base <<<'{}'
  write_host <<'JSON'
{"w": ["${TMPDIR}"]}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.w[0]'
  [ "${output}" = '"/var/folders/xx/test/T"' ]
}

@test "placeholder: GDRIVE_HANDOFF is the one Claude Handoff folder, in ~/ form" {
  mkdir -p "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/Claude Handoff"
  write_base <<<'{}'
  write_host <<'JSON'
{"w": ["${GDRIVE_HANDOFF}"]}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.w[0]'
  [ "${output}" = '"~/Library/CloudStorage/GoogleDrive-someone@example.com/My Drive/Claude Handoff"' ]
}

@test "placeholder: no Claude Handoff folder fails and keeps the old file" {
  old_file
  write_base <<<'{}'
  write_host <<'JSON'
{"w": ["${GDRIVE_HANDOFF}"]}
JSON
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"found 0"* ]]
  grep -q '"old": true' "${OUT}"
}

@test "placeholder: two Claude Handoff folders fail and keep the old file" {
  old_file
  mkdir -p "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-a@example.com/My Drive/Claude Handoff" \
    "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-b@example.com/My Drive/Claude Handoff"
  write_base <<<'{}'
  write_host <<'JSON'
{"w": ["${GDRIVE_HANDOFF}"]}
JSON
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"found 2"* ]]
  grep -q '"old": true' "${OUT}"
}

@test "placeholder: an unused GDRIVE_HANDOFF needs no folder" {
  write_base <<<'{}'
  write_host <<'JSON'
{"w": ["${HOME}"]}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.w[0]'
  [ "${output}" = "\"${FAKE_HOME}\"" ]
}

@test "placeholder: an unknown one fails, names it, and keeps the old file" {
  old_file
  write_base <<'JSON'
{"a": "${USER}/x"}
JSON
  write_host <<<'{}'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"unknown placeholder(s): USER"* ]]
  grep -q '"old": true' "${OUT}"
  leftovers '.machine-settings.*'
  [ -z "${output}" ]
}

@test "placeholder: an unknown one in a key fails too" {
  write_base <<'JSON'
{"${NOPE}": 1}
JSON
  write_host <<<'{}'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"NOPE"* ]]
  [[ ! -e "${OUT}" ]]
}

@test "check: a filled value that leaves a dollar-brace behind fails" {
  local odd_home="${TEST_ROOT}/h\${X}" odd_out="${TEST_ROOT}/out/machine-settings.json"
  mkdir -p "${odd_home}"
  write_base <<<'{}'
  write_host <<'JSON'
{"a": "${HOME}"}
JSON
  run env HOME="${odd_home}" TMPDIR="${TEST_ROOT}/tmp" bash "${SCRIPT}" --src "${SRC}" --out "${odd_out}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"failed the check"* ]]
  [[ ! -e "${odd_out}" ]]
}

# --- host file ------------------------------------------------------------------

@test "no host file: nothing is written and an existing file stays" {
  old_file
  write_base <<<'{"a": 1}'
  write_host OTHERHOST <<<'{"b": 2}'
  run build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"left as it is"* ]]
  grep -q '"old": true' "${OUT}"
  [[ ! -s "${STUB_LOG}" ]]
}

@test "no host file and no output: nothing is created" {
  write_base <<<'{"a": 1}'
  run build
  [ "${status}" -eq 0 ]
  [[ ! -e "${OUT}" ]]
}

@test "the host name is matched upper-case" {
  write_base <<<'{}'
  write_host <<<'{"h": 1}'
  MACHINE_SETTINGS_HOST="testhost" run build
  [ "${status}" -eq 0 ]
  out_json '.h'
  [ "${output}" = "1" ]
}

@test "bad JSON in the host file fails and keeps the old file" {
  old_file
  write_base <<<'{}'
  write_host <<<'{"a": '
  run build
  [ "${status}" -eq 1 ]
  grep -q '"old": true' "${OUT}"
  leftovers '.machine-settings.*'
  [ -z "${output}" ]
}

@test "bad JSON in the base file fails and keeps the old file" {
  old_file
  write_base <<<'not json'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 1 ]
  grep -q '"old": true' "${OUT}"
}

@test "a host file that is not an object fails" {
  write_base <<<'{}'
  write_host <<<'["a"]'
  run build
  [ "${status}" -eq 1 ]
  [[ ! -e "${OUT}" ]]
}

# --- write ----------------------------------------------------------------------

@test "the output is mode 600 and moved into place with the injected mv" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  run mode_of "${OUT}"
  [ "${output}" = "600" ]
  grep -q "^mv -f ${OUT%/*}/.machine-settings\.[^ ]* ${OUT}$" "${STUB_LOG}"
}

@test "the first build saves the old file once; later builds add no backup" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  local backups=("${OUT}".bak-*-pre-build)
  [ "${#backups[@]}" -eq 1 ]
  [[ -f "${backups[0]}" ]]
  grep -q '"old": true' "${backups[0]}"
  [[ "${backups[0]}" =~ \.bak-[0-9]{8}-pre-build$ ]]

  write_base <<<'{"a": 2}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = "2" ]
  backups=("${OUT}".bak-*-pre-build)
  [ "${#backups[@]}" -eq 1 ]
  grep -q '"old": true' "${backups[0]}"
}

@test "no old file: no backup" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  leftovers '*.bak-*'
  [ -z "${output}" ]
}

@test "identical content is left alone: no move" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  : >"${STUB_LOG}"
  run build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already matches"* ]]
  run grep -c '^mv ' "${STUB_LOG}"
  [ "${output}" = "0" ]
}

@test "--dry-run builds and checks but writes nothing" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"would write"* ]]
  grep -q '"old": true' "${OUT}"
  run find "${OUT%/*}" -name '*.bak-*' -o -name '.machine-settings.*'
  [ -z "${output}" ]
  run find "${TEST_ROOT}/tmp" -type f
  [ -z "${output}" ]
}

@test "--dry-run still fails on an unknown placeholder" {
  write_base <<'JSON'
{"a": "${NOPE}"}
JSON
  write_host <<<'{}'
  run build --dry-run
  [ "${status}" -eq 1 ]
}

# --- second output: --host-optional, --report, symlinked outputs -----------------

@test "--host-optional builds base.json alone when the host file is missing" {
  write_base <<<'{"b": 2, "a": {"y": 1, "x": [1]}}'
  run build --host-optional
  [ "${status}" -eq 0 ]
  run jq -S . "${OUT}"
  local got="${output}"
  run jq -S . "${SRC}/base.json"
  [ "${got}" = "${output}" ]
}

@test "without --host-optional a missing host file still writes nothing" {
  write_base <<<'{"a": 1}'
  run build
  [ "${status}" -eq 0 ]
  [[ ! -e "${OUT}" ]]
}

@test "--report writes the drift report to the given path" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  hand_edit
  run build --report "${TEST_ROOT}/r.diff"
  [ "${status}" -eq 2 ]
  [[ -f "${TEST_ROOT}/r.diff" ]]
  [[ ! -e "${FAKE_HOME}/.local/state/claude-config/machine-settings.drift.diff" ]]
}

@test "a symlinked output is replaced by a regular file, and the link target is untouched" {
  write_base <<<'{"a": 2}'
  write_host <<<'{}'
  mkdir -p "${OUT%/*}"
  printf '{"a":1}\n' >"${TEST_ROOT}/target.json"
  ln -s "${TEST_ROOT}/target.json" "${OUT}"
  run build
  [ "${status}" -eq 0 ]
  [[ ! -L "${OUT}" ]]
  [[ -f "${OUT}" ]]
  run cat "${TEST_ROOT}/target.json"
  [ "${output}" = '{"a":1}' ]
  local backups=("${OUT}".bak-*-pre-build)
  [[ -f "${backups[0]}" ]]
}

@test "a symlinked output with identical content is still replaced by a regular file" {
  local with_built
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  for with_built in no yes; do
    rm -rf "${OUT%/*}"
    mkdir -p "${OUT%/*}"
    printf '{"a":1}\n' >"${TEST_ROOT}/target.json"
    ln -s "${TEST_ROOT}/target.json" "${OUT}"
    if [ "${with_built}" = yes ]; then
      printf '{"a":1}\n' >"${OUT}.built"
    fi
    run build
    [ "${status}" -eq 0 ]
    [[ ! -L "${OUT}" ]]
    [[ -f "${OUT}" ]]
    run jq -c . "${OUT}"
    [ "${output}" = '{"a":1}' ]
    run cat "${TEST_ROOT}/target.json"
    [ "${output}" = '{"a":1}' ]
  done
}

@test "a dangling symlink output is replaced by a regular file" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  mkdir -p "${OUT%/*}"
  ln -s "${TEST_ROOT}/gone.json" "${OUT}"
  run build
  [ "${status}" -eq 0 ]
  [[ ! -L "${OUT}" ]]
  [[ -f "${OUT}" ]]
}

# --- hand edits: the .built record and drift ------------------------------------

REPORT_REL=".local/state/claude-config/machine-settings.drift.diff"

@test "built record: the first build records exactly what it wrote, mode 600" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  cmp -s "${OUT}" "${OUT}.built"
  run mode_of "${OUT}.built"
  [ "${output}" = "600" ]
  grep -q "^mv -f ${OUT%/*}/.machine-settings\.built\.[^ ]* ${OUT}.built$" "${STUB_LOG}"
}

@test "built record: a first run whose live file already matches writes nothing and records .built" {
  mkdir -p "${OUT%/*}"
  printf '{"a":1}\n' >"${OUT}"
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  run cat "${OUT}"
  [ "${output}" = '{"a":1}' ]
  [[ -f "${OUT}.built" ]]
  leftovers '*.bak-*'
  [ -z "${output}" ]
}

@test "built record: no record but an older, different backup: the live file is still saved" {
  old_file
  printf '{"older": true}\n' >"${OUT}.bak-20260101-pre-build"
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  run grep -l '"old": true' "${OUT%/*}"/machine-settings.json.bak-*-pre-build
  [ "${status}" -eq 0 ]
  grep -q '"older": true' "${OUT}.bak-20260101-pre-build"
}

@test "built record: unchanged live file plus a repo change writes and updates .built" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  write_base <<<'{"a": 2}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = "2" ]
  cmp -s "${OUT}" "${OUT}.built"
}

@test "drift: a hand edit with no repo change is kept, reported, and fails" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  hand_edit
  cp "${OUT}" "${TEST_ROOT}/edited"
  cp "${OUT}.built" "${TEST_ROOT}/built-before"
  : >"${STUB_LOG}"
  run build
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"DRIFT: ${OUT} was edited by hand"* ]]
  [[ "${output}" == *"via a PR"* ]]
  [[ "${output}" == *"${FAKE_HOME}/${REPORT_REL}"* ]]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
  cmp -s "${OUT}.built" "${TEST_ROOT}/built-before"
  grep -q '^+ *"hand": "edit"' "${FAKE_HOME}/${REPORT_REL}"
  [[ -f "${FAKE_HOME}/.local/state/claude-config/machine-settings.drift.built.json" ]]
  [[ -f "${FAKE_HOME}/.local/state/claude-config/machine-settings.drift.live.json" ]]
  run grep -c '^mv ' "${STUB_LOG}"
  [ "${output}" = "0" ]
}

@test "drift: a repo change does not override a hand edit either" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  hand_edit
  cp "${OUT}" "${TEST_ROOT}/edited"
  write_base <<<'{"a": 2}'
  run build
  [ "${status}" -eq 2 ]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
}

@test "drift: it persists across runs until the repo catches up, then clears" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  hand_edit
  run build
  [ "${status}" -eq 2 ]
  run build
  [ "${status}" -eq 2 ]
  [[ -f "${FAKE_HOME}/${REPORT_REL}" ]]
  cp "${OUT}" "${TEST_ROOT}/edited"

  # The edit lands in the repo: the new build equals the live file.
  write_base <<<'{"a": 1, "hand": "edit"}'
  : >"${STUB_LOG}"
  run build
  [ "${status}" -eq 0 ]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
  run jq -S . "${OUT}.built"
  [[ "${output}" == *'"hand": "edit"'* ]]
  run grep -c " ${OUT}\$" "${STUB_LOG}"
  [ "${output}" = "0" ]
  [[ ! -e "${FAKE_HOME}/${REPORT_REL}" ]]

  # And the next repo change writes normally again.
  write_base <<<'{"a": 3, "hand": "edit"}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = "3" ]
}

@test "drift: a dry run reports it, fails, and writes nothing" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  hand_edit
  cp "${OUT}" "${TEST_ROOT}/edited"
  cp "${OUT}.built" "${TEST_ROOT}/built-before"
  : >"${STUB_LOG}"
  run build --dry-run
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"dry run: DRIFT"* ]]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
  cmp -s "${OUT}.built" "${TEST_ROOT}/built-before"
  [[ ! -e "${FAKE_HOME}/${REPORT_REL}" ]]
  run grep -c '^mv ' "${STUB_LOG}"
  [ "${output}" = "0" ]
}

@test "drift: a reformatted but equal live file is not drift" {
  write_base <<<'{"a": 1, "b": [1, 2]}'
  write_host <<<'{}'
  run build
  jq -S -c . "${OUT}" >"${TEST_ROOT}/edit.json"
  cat "${TEST_ROOT}/edit.json" >"${OUT}"
  run build
  [ "${status}" -eq 0 ]
}

# --- three-way merge (resolved) ---------------------------------------------------

# The live file gets the jq edit $1.
live_edit() {
  jq -c "$1" "${OUT}" >"${TEST_ROOT}/edit.json"
  cat "${TEST_ROOT}/edit.json" >"${OUT}"
}

@test "resolved: a local edit the new build already holds is written over, exit 0, report cleared" {
  write_base <<<'{"a": 1, "allow": ["x"]}'
  write_host <<<'{}'
  run build
  live_edit '.allow += ["mine"]'
  # Drift first, so a report exists for the resolved run to clear.
  run build
  [ "${status}" -eq 2 ]
  [[ -f "${FAKE_HOME}/${REPORT_REL}" ]]
  # Main gains the local rule and another change.
  write_base <<<'{"a": 2, "allow": ["x", "other", "mine"]}'
  run build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"drift resolved"* ]]
  out_json '.'
  [ "${output}" = '{"a":2,"allow":["x","other","mine"]}' ]
  cmp -s "${OUT}" "${OUT}.built"
  [[ ! -e "${FAKE_HOME}/${REPORT_REL}" ]]
  [[ ! -e "${FAKE_HOME}/.local/state/claude-config/machine-settings.drift.live.json" ]]
}

@test "resolved: a local edit the new build lacks is still drift, exit 2, nothing written" {
  write_base <<<'{"a": 1, "allow": ["x"]}'
  write_host <<<'{}'
  run build
  live_edit '.allow += ["mine"]'
  cp "${OUT}" "${TEST_ROOT}/edited"
  write_base <<<'{"a": 2, "allow": ["x", "other"]}'
  run build
  [ "${status}" -eq 2 ]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
}

@test "resolved: a changed scalar must match the new build's value" {
  write_base <<<'{"a": 1, "b": 1}'
  write_host <<<'{}'
  run build
  live_edit '.a = 5'
  write_base <<<'{"a": 6, "b": 2}'
  run build
  [ "${status}" -eq 2 ]
  write_base <<<'{"a": 5, "b": 2}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.'
  [ "${output}" = '{"a":5,"b":2}' ]
}

@test "resolved: a local removal the new build also lacks resolves; one it keeps is drift" {
  write_base <<<'{"a": 1, "gone": true, "allow": ["x", "y"]}'
  write_host <<<'{}'
  run build
  live_edit 'del(.gone) | .allow -= ["y"]'
  write_base <<<'{"a": 2, "gone": true, "allow": ["x"]}'
  run build
  [ "${status}" -eq 2 ]
  write_base <<<'{"a": 2, "allow": ["x"]}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.'
  [ "${output}" = '{"a":2,"allow":["x"]}' ]
}

@test "resolved: array order does not matter" {
  write_base <<<'{"allow": ["x", "y"]}'
  write_host <<<'{}'
  run build
  live_edit '.allow = ["y", "x", "z"]'
  write_base <<<'{"allow": ["z", "x", "y"]}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.allow'
  [ "${output}" = '["z","x","y"]' ]
}

@test "resolved: an added object must be held whole" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  live_edit '.o = {"p": 1, "q": [1]}'
  write_base <<<'{"a": 1, "o": {"p": 1}}'
  run build
  [ "${status}" -eq 2 ]
  write_base <<<'{"a": 1, "o": {"p": 1, "q": [1], "r": 2}}'
  run build
  [ "${status}" -eq 0 ]
}

@test "resolved: an unreadable .built is drift, not a failure" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  live_edit '.b = 1'
  printf 'not json\n' >"${OUT}.built"
  write_base <<<'{"a": 1, "b": 1, "c": 1}'
  run build
  [ "${status}" -eq 2 ]
}

@test "resolved: a dry run says it would write, exits 0, and writes nothing" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  run build
  live_edit '.b = 1'
  cp "${OUT}" "${TEST_ROOT}/edited"
  cp "${OUT}.built" "${TEST_ROOT}/built-before"
  write_base <<<'{"a": 2, "b": 1}'
  : >"${STUB_LOG}"
  run build --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"(resolved)"* ]]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
  cmp -s "${OUT}.built" "${TEST_ROOT}/built-before"
  run grep -c '^mv ' "${STUB_LOG}"
  [ "${output}" = "0" ]
}

# --- local overlay ------------------------------------------------------------

@test "local: merged last, arrays append in base, host, local order and a local scalar wins" {
  write_base <<'JSON'
{"autoMode": {"allow": ["b1"]}, "s": "base", "t": "base"}
JSON
  write_host <<'JSON'
{"autoMode": {"allow": ["h1"]}, "s": "host"}
JSON
  write_local <<'JSON'
{"autoMode": {"allow": ["l1"]}, "s": "local"}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.autoMode.allow'
  [ "${output}" = '["b1","h1","l1"]' ]
  out_json '.s'
  [ "${output}" = '"local"' ]
  out_json '.t'
  [ "${output}" = '"base"' ]
}

@test "local: a missing local file builds the same as the build before it existed" {
  write_base <<<'{"a": [1], "b": "base"}'
  write_host <<<'{"a": [2]}'
  run build --local "${TEST_ROOT}/absent.local.json"
  [ "${status}" -eq 0 ]
  jq -S . "${OUT}" >"${TEST_ROOT}/with-option.json"
  rm -f "${OUT}" "${OUT}.built"
  run build
  [ "${status}" -eq 0 ]
  jq -S . "${OUT}" >"${TEST_ROOT}/without.json"
  cmp "${TEST_ROOT}/with-option.json" "${TEST_ROOT}/without.json"
}

@test "local: invalid JSON fails, names the local path and keeps the old file" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_local <<<'{not json'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"machine-settings.local.json"* ]]
  grep -q '"old": true' "${OUT}"
}

@test "local: a JSON array fails and keeps the old file" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_local <<<'["x"]'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"machine-settings.local.json"* ]]
  grep -q '"old": true' "${OUT}"
}

@test "local: --local beats MACHINE_SETTINGS_LOCAL, which beats the default" {
  write_base <<<'{"v": "base"}'
  write_host <<<'{}'
  write_local <<<'{"v": "default"}'
  printf '{"v": "env"}\n' >"${TEST_ROOT}/env.json"
  printf '{"v": "option"}\n' >"${TEST_ROOT}/option.json"
  MACHINE_SETTINGS_LOCAL="${TEST_ROOT}/env.json" run build
  [ "${status}" -eq 0 ]
  out_json '.v'
  [ "${output}" = '"env"' ]
  MACHINE_SETTINGS_LOCAL="${TEST_ROOT}/env.json" run build --local "${TEST_ROOT}/option.json"
  [ "${status}" -eq 0 ]
  out_json '.v'
  [ "${output}" = '"option"' ]
}

@test "local: no host file and no --host-optional writes nothing, even with a local file" {
  write_base <<<'{"a": 1}'
  write_local <<<'{"b": 2}'
  run build
  [ "${status}" -eq 0 ]
  [ ! -e "${OUT}" ]
}

@test "local: --host-optional still merges the local file" {
  write_base <<<'{"a": [1]}'
  write_local <<<'{"a": [2]}'
  run build --host-optional
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = '[1,2]' ]
}

@test "local: a HOME placeholder in the local file is filled" {
  write_base <<<'{}'
  write_host <<<'{}'
  write_local <<'JSON'
{"list": ["${HOME}/x *"]}
JSON
  run build
  [ "${status}" -eq 0 ]
  out_json '.list'
  [ "${output}" = "[\"${FAKE_HOME}/x *\"]" ]
}

@test "local: editing only the local file rebuilds with exit 0 and no drift report" {
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_local <<<'{"b": 1}'
  run build
  [ "${status}" -eq 0 ]
  write_local <<<'{"b": 2}'
  MACHINE_SETTINGS_DRIFT_REPORT="${TEST_ROOT}/drift.diff" run build
  [ "${status}" -eq 0 ]
  out_json '.b'
  [ "${output}" = "2" ]
  [ ! -e "${TEST_ROOT}/drift.diff" ]
}

@test "local: the build never logs the local file's content" {
  write_base <<<'{}'
  write_host <<<'{}'
  write_local <<<'{"secret": "dummy-internal-value"}'
  run build
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"dummy-internal-value"* ]]
}

# --- groups ---------------------------------------------------------------------

write_groups() { cat >"${SRC}/groups.json"; }
write_group() { mkdir -p "${SRC}/groups" && cat >"${SRC}/groups/$1.json"; }

@test "groups: base, then group, then host, then local; arrays append as the host layer's do" {
  write_base <<<'{"autoMode": {"allow": ["b1"]}, "s": "base", "t": "base", "u": "base"}'
  write_groups <<<'{"personal": ["OTHER", "TESTHOST"]}'
  write_group personal <<<'{"autoMode": {"allow": ["g1"]}, "s": "group", "t": "group", "u": "group"}'
  write_host <<<'{"autoMode": {"allow": ["h1"]}, "s": "host", "t": "host"}'
  write_local <<<'{"autoMode": {"allow": ["l1"]}, "s": "local"}'
  run build
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"merging the group file ${SRC}/groups/personal.json"* ]]
  out_json '.autoMode.allow'
  [ "${output}" = '["b1","g1","h1","l1"]' ]
  out_json '[.s, .t, .u]'
  [ "${output}" = '["local","host","group"]' ]
}

@test "groups: two groups listing the host apply in groups.json order, not name order" {
  write_base <<<'{"a": ["b"], "s": "base"}'
  write_groups <<<'{"zeta": ["TESTHOST"], "alpha": ["TESTHOST"]}'
  write_group zeta <<<'{"a": ["z"], "s": "zeta"}'
  write_group alpha <<<'{"a": ["a"], "s": "alpha"}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  out_json '.a'
  [ "${output}" = '["b","z","a"]' ]
  out_json '.s'
  [ "${output}" = '"alpha"' ]
}

@test "groups: a host in no group builds byte-identical to a build with no groups.json" {
  write_base <<<'{"a": ["b"], "s": "base", "o": {"k": 1}}'
  write_host <<<'{"a": ["h"], "o": {"j": 2}}'
  run build --out "${TEST_ROOT}/without.json" --local "${TEST_ROOT}/absent.json"
  [ "${status}" -eq 0 ]
  write_groups <<<'{"personal": ["OTHER"]}'
  write_group personal <<<'{"a": ["g"], "s": "group"}'
  run build --out "${TEST_ROOT}/with.json" --local "${TEST_ROOT}/absent.json"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"group file"* ]]
  cmp "${TEST_ROOT}/without.json" "${TEST_ROOT}/with.json"
}

@test "groups: a listed group whose file is missing fails, names the file, and keeps the old file" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_groups <<<'{"personal": ["TESTHOST"]}'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"${SRC}/groups/personal.json is missing"* ]]
  out_json '.'
  [ "${output}" = '{"old":true}' ]
}

@test "groups: invalid JSON or the wrong shape in groups.json fails and keeps the old file" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_group personal <<<'{}'
  local bad
  for bad in 'not json' '["TESTHOST"]' '{"personal": "TESTHOST"}' '{"personal": [1]}' \
    '{"personal": ["testhost"]}' '{"../x": ["TESTHOST"]}' '{"a": []} {"b": []}'; do
    printf '%s\n' "${bad}" >"${SRC}/groups.json"
    run build
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"bad ${SRC}/groups.json"* ]]
    out_json '.'
    [ "${output}" = '{"old":true}' ]
  done
}

@test "groups: a group file that is not a JSON object fails, names it, and keeps the old file" {
  old_file
  write_base <<<'{"a": 1}'
  write_host <<<'{}'
  write_groups <<<'{"personal": ["TESTHOST"]}'
  write_group personal <<<'["x"]'
  run build
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"cannot merge the group file ${SRC}/groups/personal.json"* ]]
  out_json '.'
  [ "${output}" = '{"old":true}' ]
}

@test "groups: --host-optional with no host file builds base plus the host's groups" {
  write_base <<<'{"a": ["b"], "s": "base"}'
  write_groups <<<'{"personal": ["TESTHOST"]}'
  write_group personal <<<'{"a": ["g"], "s": "group"}'
  run build --host-optional
  [ "${status}" -eq 0 ]
  out_json '.'
  [ "${output}" = '{"a":["b","g"],"s":"group"}' ]
}

@test "groups: a hand edit a group file now supplies resolves, not drift" {
  write_base <<<'{"a": ["b"]}'
  write_host <<<'{}'
  run build
  [ "${status}" -eq 0 ]
  jq -c '.a += ["g"]' "${OUT}" >"${TEST_ROOT}/edit.json"
  cat "${TEST_ROOT}/edit.json" >"${OUT}"
  write_groups <<<'{"personal": ["TESTHOST"]}'
  write_group personal <<<'{"a": ["g"], "x": 1}'
  run build --report "${TEST_ROOT}/drift.diff"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"drift resolved"* ]]
  out_json '.'
  [ "${output}" = '{"a":["b","g"],"x":1}' ]
}

# --- the real source files ------------------------------------------------------

@test "repo sources: machine-settings/ has no groups, so it gets no group layer" {
  local src="${BATS_TEST_DIRNAME}/../machine-settings" f host
  [[ ! -e "${src}/groups.json" && ! -e "${src}/groups" ]]
  mkdir -p "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Claude Handoff"
  for f in "${src}"/hosts/*.json; do
    host="${f##*/}"
    host="${host%.json}"
    MACHINE_SETTINGS_HOST="${host}" run build --src "${src}" --out "${TEST_ROOT}/new-${host}.json"
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"group file"* ]]
  done
}

@test "repo sources: machine-settings/ builds byte-identical to the build before groups" {
  local src="${BATS_TEST_DIRNAME}/../machine-settings" old="${TEST_ROOT}/old-build.sh" f host
  # The build as it was before the group layer: 281459c, the commit this layer is based on.
  git -C "${BATS_TEST_DIRNAME}/.." show 281459c:scripts/build-machine-settings.sh >"${old}" ||
    skip "281459c is not in this clone (a shallow checkout); the old build cannot be compared"
  mkdir -p "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Claude Handoff"
  for f in "${src}"/hosts/*.json; do
    host="${f##*/}"
    host="${host%.json}"
    MACHINE_SETTINGS_HOST="${host}" run build --src "${src}" --out "${TEST_ROOT}/new-${host}.json"
    [ "${status}" -eq 0 ]
    SCRIPT="${old}" MACHINE_SETTINGS_HOST="${host}" run build --src "${src}" --out "${TEST_ROOT}/old-${host}.json"
    [ "${status}" -eq 0 ]
    cmp "${TEST_ROOT}/new-${host}.json" "${TEST_ROOT}/old-${host}.json"
  done
}

@test "repo sources: base.json and every host file build, with no private values" {
  local src="${BATS_TEST_DIRNAME}/../machine-settings" f host
  [[ -f "${src}/base.json" ]]
  run grep -rqE '@gmail|/var/folders|/Users/' "${src}"
  [ "${status}" -eq 1 ]
  mkdir -p "${FAKE_HOME}/Library/CloudStorage/GoogleDrive-x@example.com/My Drive/Claude Handoff"
  for f in "${src}"/hosts/*.json; do
    host="${f##*/}"
    host="${host%.json}"
    MACHINE_SETTINGS_HOST="${host}" run build --src "${src}"
    [ "${status}" -eq 0 ]
    jq -e 'type == "object"' "${OUT}" >/dev/null
  done
}

@test "repo sources: user-settings/ builds for every host file and with none, with no private values" {
  local src="${BATS_TEST_DIRNAME}/../user-settings" f host
  [[ -f "${src}/base.json" ]]
  run grep -rqE '@gmail|/var/folders|/Users/' "${src}"
  [ "${status}" -eq 1 ]
  for f in "${src}"/hosts/*.json "${src}/hosts/NO-SUCH-HOST.json"; do
    host="${f##*/}"
    host="${host%.json}"
    rm -f "${OUT}" "${OUT}.built"
    MACHINE_SETTINGS_HOST="${host}" run build --src "${src}" --host-optional --local "${TEST_ROOT}/absent.json"
    [ "${status}" -eq 0 ]
    jq -e 'type == "object" and has("autoMode")' "${OUT}" >/dev/null
  done
}

# --- install.sh -------------------------------------------------------------------

# A minimal repo install.sh accepts, plus the build script and a source tree.
make_repo() {
  local dir="$1"
  mkdir -p "${dir}/hooks" "${dir}/scripts" "${dir}/machine-settings/hosts"
  GIT_CONFIG_GLOBAL=/dev/null git -C "${dir}" init -q
  git -C "${dir}" config user.email "test@test.com"
  git -C "${dir}" config user.name "Test"
  git -C "${dir}" config commit.gpgSign false
  cp "${BATS_TEST_DIRNAME}/../install.sh" "${dir}/install.sh"
  cp "${SCRIPT}" "${dir}/scripts/build-machine-settings.sh"
  chmod +x "${dir}/scripts/build-machine-settings.sh"
  mkdir -p "${dir}/user-settings" && printf '{}\n' >"${dir}/user-settings/base.json"
  printf '# test\n' >"${dir}/CLAUDE.md"
  printf '#!/usr/bin/env bash\n' >"${dir}/hooks/run-review.sh"
  chmod +x "${dir}/hooks/run-review.sh"
  printf '{"autoMode": {"allow": ["d0"]}}\n' >"${dir}/machine-settings/base.json"
  cat >"${dir}/machine-settings/hosts/TESTHOST.json" <<'JSON'
{"autoMode": {"allow": ["host rule"]}, "hooks": {"c": "${HOME}/h.sh"}}
JSON
  git -C "${dir}" add install.sh user-settings/base.json CLAUDE.md hooks/run-review.sh \
    scripts/build-machine-settings.sh machine-settings/base.json machine-settings/hosts/TESTHOST.json
  GIT_CONFIG_GLOBAL=/dev/null git -C "${dir}" commit -q -m "initial"
}

setup_install() {
  local os
  os="$(uname -s)"
  [[ "${os}" == "Darwin" ]] || skip "install.sh is macOS-only"
  DEPLOY="${FAKE_HOME}/.claude"
  CLONE="${FAKE_HOME}/.local/share/claude-config"
  DEV="${FAKE_HOME}/Developer/claude-config"
  mkdir -p "${DEPLOY}"
  make_repo "${DEV}"
}

run_install() {
  local repo="$1"
  shift
  HOME="${FAKE_HOME}" TMPDIR="${TEST_ROOT}/tmp" bash "${repo}/install.sh" "$@" 2>&1
}

@test "install: the deploy clone's --sync builds the file" {
  setup_install
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  out_json '.autoMode.allow'
  [ "${output}" = '["d0","host rule"]' ]
  out_json '.hooks.c'
  [ "${output}" = "\"${FAKE_HOME}/h.sh\"" ]
  run mode_of "${OUT}"
  [ "${output}" = "600" ]
}

@test "install: machine-settings/ is not linked into ~/.claude" {
  setup_install
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ ! -e "${DEPLOY}/machine-settings" && ! -L "${DEPLOY}/machine-settings" ]]
  [[ -L "${DEPLOY}/scripts/build-machine-settings.sh" ]]
}

@test "install: --dev never builds the file" {
  setup_install
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Not the deploy clone"* ]]
  [[ ! -e "${OUT}" ]]
}

@test "install: a checkout that is not the deploy clone never builds the file" {
  setup_install
  run run_install "${DEV}" --sync
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Not the deploy clone"* ]]
  [[ ! -e "${OUT}" ]]
}

@test "install: the clone's --sync --dry-run writes nothing" {
  setup_install
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry run: would write ${OUT}"* ]]
  [[ ! -e "${OUT}" ]]
}

@test "install: a failed build fails the deploy and keeps the old file" {
  setup_install
  make_repo "${CLONE}"
  cat >"${CLONE}/machine-settings/hosts/TESTHOST.json" <<'JSON'
{"a": "${NOPE}"}
JSON
  git -C "${CLONE}" add machine-settings/hosts/TESTHOST.json
  GIT_CONFIG_GLOBAL=/dev/null git -C "${CLONE}" commit -q -m "bad"
  old_file
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"Machine settings build failed"* ]]
  [[ "${output}" == *"! machine-settings"* ]]
  grep -q '"old": true' "${OUT}"
}

@test "install: drift fails the deploy and keeps the hand edit" {
  setup_install
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  hand_edit
  cp "${OUT}" "${TEST_ROOT}/edited"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"DRIFT"* ]]
  [[ "${output}" == *"! machine-settings"* ]]
  cmp -s "${OUT}" "${TEST_ROOT}/edited"
}
