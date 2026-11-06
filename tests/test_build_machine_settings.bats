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

# --- the real source files ------------------------------------------------------

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
  printf '{}\n' >"${dir}/settings.json"
  printf '# test\n' >"${dir}/CLAUDE.md"
  printf '#!/usr/bin/env bash\n' >"${dir}/hooks/run-review.sh"
  chmod +x "${dir}/hooks/run-review.sh"
  printf '{"autoMode": {"allow": ["d0"]}}\n' >"${dir}/machine-settings/base.json"
  cat >"${dir}/machine-settings/hosts/TESTHOST.json" <<'JSON'
{"autoMode": {"allow": ["host rule"]}, "hooks": {"c": "${HOME}/h.sh"}}
JSON
  git -C "${dir}" add install.sh settings.json CLAUDE.md hooks/run-review.sh \
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
