#!/usr/bin/env bats
# install.sh and the deploy clone (#453).
#
# ~/.claude links into a separate clone at ~/.local/share/claude-config. The
# working checkout ~/Developer/claude-config is for editing. Once the clone
# exists, the working checkout install.sh hands every run except --dev to
# the clone: the old instruction "run ~/Developer/claude-config/install.sh
# --sync" (docs, habits, dotfiles allup and dotclaude) would otherwise
# silently put the machine back into working-tree mode.
#
# Isolation: a throwaway HOME holds both checkouts and ~/.claude, so the real
# ~/.claude, ~/.local/share and ~/.local/state are never touched.
#
# Run: bats tests/test_install_deploy_clone.bats

setup() {
  [[ "$(uname -s)" == "Darwin" ]] || skip "install.sh is macOS-only"
  TMPDIR_TEST="$(mktemp -d)"
  FAKE_HOME="${TMPDIR_TEST}/home"
  DEPLOY="${FAKE_HOME}/.claude"
  CLONE="${FAKE_HOME}/.local/share/claude-config"
  DEV="${FAKE_HOME}/Developer/claude-config"
  MARKER="${FAKE_HOME}/.local/state/claude-config/dev-mode"
  mkdir -p "${DEPLOY}"
  make_repo "${DEV}"
}

teardown() {
  rm -rf "${TMPDIR_TEST}"
}

# A minimal repo that install.sh accepts: its canary files plus install.sh.
make_repo() {
  local dir="$1"
  mkdir -p "${dir}/hooks"
  GIT_CONFIG_GLOBAL=/dev/null git -C "${dir}" init -q
  git -C "${dir}" config user.email "test@test.com"
  git -C "${dir}" config user.name "Test"
  git -C "${dir}" config commit.gpgSign false
  cp "${BATS_TEST_DIRNAME}/../install.sh" "${dir}/install.sh"
  printf '{}\n' >"${dir}/settings.json"
  printf '# test\n' >"${dir}/CLAUDE.md"
  printf '#!/usr/bin/env bash\n' >"${dir}/hooks/run-review.sh"
  chmod +x "${dir}/hooks/run-review.sh"
  git -C "${dir}" add install.sh settings.json CLAUDE.md hooks/run-review.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${dir}" commit -q -m "initial"
}

run_install() {
  local repo="$1"
  shift
  HOME="${FAKE_HOME}" bash "${repo}/install.sh" "$@" 2>&1
}

# --- before the clone exists: unchanged ------------------------------------

@test "no deploy clone yet: the working checkout's --sync links ~/.claude to it" {
  run run_install "${DEV}" --sync
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/CLAUDE.md")" == "${DEV}/CLAUDE.md" ]]
}

# --- the working checkout hands off once the clone exists -------------------

# A stub deploy script in the clone: records its arguments and exits with
# STUB_DEPLOY_RC, so these cases never fetch or relink.
add_deploy_stub() {
  mkdir -p "${CLONE}/scripts"
  cat >"${CLONE}/scripts/claude-config-deploy.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_DEPLOY_LOG}"
exit "${STUB_DEPLOY_RC:-0}"
STUB
  chmod +x "${CLONE}/scripts/claude-config-deploy.sh"
  export STUB_DEPLOY_LOG="${TMPDIR_TEST}/deploy.log"
}

@test "clone exists: the working checkout's --sync runs the deploy instead" {
  make_repo "${CLONE}"
  add_deploy_stub
  run run_install "${DEV}" --sync
  [ "${status}" -eq 0 ]
  grep -qx "deploy" "${STUB_DEPLOY_LOG}"
  [[ "${output}" == *"claude-config-deploy"* ]]
  [[ ! -e "${DEPLOY}/CLAUDE.md" && ! -L "${DEPLOY}/CLAUDE.md" ]]
}

@test "clone exists: the working checkout's full install runs the deploy instead" {
  make_repo "${CLONE}"
  add_deploy_stub
  run run_install "${DEV}"
  [ "${status}" -eq 0 ]
  grep -qx "deploy" "${STUB_DEPLOY_LOG}"
  [[ ! -L "${DEPLOY}/CLAUDE.md" ]]
}

@test "clone exists: the deploy's exit status comes back, so allup still stops on a failure" {
  make_repo "${CLONE}"
  add_deploy_stub
  STUB_DEPLOY_RC=2 run run_install "${DEV}" --sync
  [ "${status}" -eq 2 ]
}

@test "clone exists: the working checkout's --repair repairs from the clone" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  ln -sfn "${TMPDIR_TEST}/gone/run-review.sh" "${DEPLOY}/hooks/run-review.sh"
  run run_install "${DEV}" --repair
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/hooks/run-review.sh")" == "${CLONE}/hooks/run-review.sh" ]]
}

@test "clone exists: a working-checkout dry run reports the clone's plan and changes nothing" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --sync --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"Would symlink: ${DEPLOY}/CLAUDE.md -> ${CLONE}/CLAUDE.md"* ]]
  [[ ! -L "${DEPLOY}/CLAUDE.md" ]]
}

@test "clone exists but has no deploy script: --sync refuses and links nothing" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --sync
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"--dev"* ]]
  [[ ! -L "${DEPLOY}/CLAUDE.md" ]]
}

@test "a hand-off is not reported as an install of the working checkout" {
  make_repo "${CLONE}"
  add_deploy_stub
  run run_install "${DEV}" --sync
  [[ "${output}" != *"claude-config: installing"* ]]
}

# --- dev mode ---------------------------------------------------------------

@test "--dev links ~/.claude to the working checkout and records dev mode" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/CLAUDE.md")" == "${DEV}/CLAUDE.md" ]]
  [[ -f "${MARKER}" ]]
  grep -qx "path=${DEV}" "${MARKER}"
  grep -qE '^since=[0-9]+$' "${MARKER}"
  [[ "${output}" == *"DEV MODE"* ]]
}

@test "--dev from the deploy clone is refused" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --dev
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"working checkout"* ]]
  [[ ! -f "${MARKER}" ]]
}

@test "--dev and --repair together are rejected" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev --repair
  [ "${status}" -ne 0 ]
  [[ ! -f "${MARKER}" ]]
}

@test "--dev --dry-run changes nothing and records no dev mode" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev --dry-run
  [ "${status}" -eq 0 ]
  [[ ! -L "${DEPLOY}/CLAUDE.md" ]]
  [[ ! -f "${MARKER}" ]]
}

# --- the clone's --sync is the deploy --------------------------------------

@test "the clone's --sync links ~/.claude to the clone" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/CLAUDE.md")" == "${CLONE}/CLAUDE.md" ]]
  [[ "$(readlink "${DEPLOY}/hooks/run-review.sh")" == "${CLONE}/hooks/run-review.sh" ]]
}

@test "the clone's --sync ends dev mode: relinks and removes the marker" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  [[ -f "${MARKER}" ]]

  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/CLAUDE.md")" == "${CLONE}/CLAUDE.md" ]]
  [[ ! -e "${MARKER}" ]]
}

@test "the clone's --sync removes a working-checkout link for a file the clone does not track" {
  make_repo "${CLONE}"
  mkdir -p "${DEV}/scripts"
  printf '#!/usr/bin/env bash\n' >"${DEV}/scripts/feature-only.sh"
  chmod +x "${DEV}/scripts/feature-only.sh"
  git -C "${DEV}" add scripts/feature-only.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${DEV}" commit -q -m "feature"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  [[ -L "${DEPLOY}/scripts/feature-only.sh" ]]

  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  # It resolves, so the dangling-link prune alone would have kept it.
  [[ ! -L "${DEPLOY}/scripts/feature-only.sh" ]]
  [[ "${output}" == *"pruned:${DEPLOY}/scripts/feature-only.sh"* ]]
}

@test "the clone's --sync leaves links to unrelated places alone" {
  make_repo "${CLONE}"
  mkdir -p "${DEPLOY}/debug" "${TMPDIR_TEST}/elsewhere"
  printf 'x\n' >"${TMPDIR_TEST}/elsewhere/latest"
  ln -s "${TMPDIR_TEST}/elsewhere/latest" "${DEPLOY}/debug/latest"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ -L "${DEPLOY}/debug/latest" ]]
}

# --- the clone must stay clean ----------------------------------------------

@test "the clone's --repair backs up a regular file instead of copying it into the clone" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  # An atomic write replaced the link with a regular file holding an edit.
  rm "${DEPLOY}/CLAUDE.md"
  printf '# edited in place\n' >"${DEPLOY}/CLAUDE.md"

  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  [[ "$(readlink "${DEPLOY}/CLAUDE.md")" == "${CLONE}/CLAUDE.md" ]]
  [[ -z "$(git -C "${CLONE}" status --porcelain --untracked-files=no)" ]]
  grep -rqx '# edited in place' "${DEPLOY}/backups/symlink-migration"
  [[ "${output}" == *"Backed up"* ]]
}

@test "the clone's --repair also leaves the edit in the working checkout, unstaged" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  rm "${DEPLOY}/CLAUDE.md"
  printf '# edited in place\n' >"${DEPLOY}/CLAUDE.md"

  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  grep -qx '# edited in place' "${DEV}/CLAUDE.md"
  [[ -z "$(git -C "${DEV}" diff --cached --name-only)" ]]
  [[ "${output}" == *"${DEV}/CLAUDE.md"* ]]
}

@test "the clone's --repair never overwrites uncommitted work in the working checkout" {
  make_repo "${CLONE}"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  printf '# uncommitted work\n' >"${DEV}/CLAUDE.md"
  rm "${DEPLOY}/CLAUDE.md"
  printf '# edited in place\n' >"${DEPLOY}/CLAUDE.md"

  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  grep -qx '# uncommitted work' "${DEV}/CLAUDE.md"
  grep -rqx '# edited in place' "${DEPLOY}/backups/symlink-migration"
  [[ "${output}" == *"has uncommitted changes"* ]]
}

@test "the clone's --repair never overwrites an untracked file in the working checkout" {
  make_repo "${CLONE}"
  mkdir -p "${CLONE}/scripts"
  printf 'v1\n' >"${CLONE}/scripts/only-in-clone.txt"
  git -C "${FAKE_HOME}/.local/share/claude-config" add scripts/only-in-clone.txt
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_HOME}/.local/share/claude-config" commit -q -m "clone file"
  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  mkdir -p "${DEV}/scripts"
  printf 'untracked work\n' >"${DEV}/scripts/only-in-clone.txt"
  rm "${DEPLOY}/scripts/only-in-clone.txt"
  printf 'edited in place\n' >"${DEPLOY}/scripts/only-in-clone.txt"

  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  grep -qx 'untracked work' "${DEV}/scripts/only-in-clone.txt"
}

@test "the working checkout's repair still copies an edit back into it (legacy)" {
  run run_install "${DEV}" --sync
  [ "${status}" -eq 0 ]
  rm "${DEPLOY}/CLAUDE.md"
  printf '# edited in place\n' >"${DEPLOY}/CLAUDE.md"

  run run_install "${DEV}" --repair
  [ "${status}" -eq 0 ]
  grep -qx '# edited in place' "${DEV}/CLAUDE.md"
}

# --- review findings on the first commit -------------------------------------

@test "the clone's --repair keeps the dev-mode marker while dev links remain" {
  make_repo "${CLONE}"
  run run_install "${DEV}" --dev
  [ "${status}" -eq 0 ]
  run run_install "${CLONE}" --repair
  [ "${status}" -eq 0 ]
  [[ -f "${MARKER}" ]]
}

@test "the clone's --sync removes leftovers of --dev run from a checkout elsewhere" {
  make_repo "${CLONE}"
  OTHER="${FAKE_HOME}/src/claude-config"
  make_repo "${OTHER}"
  mkdir -p "${OTHER}/scripts"
  printf '#!/usr/bin/env bash\n' >"${OTHER}/scripts/feature-only.sh"
  chmod +x "${OTHER}/scripts/feature-only.sh"
  git -C "${FAKE_HOME}/src/claude-config" add scripts/feature-only.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${FAKE_HOME}/src/claude-config" commit -q -m "feature"
  run run_install "${OTHER}" --dev
  [ "${status}" -eq 0 ]
  [[ -L "${DEPLOY}/scripts/feature-only.sh" ]]

  run run_install "${CLONE}" --sync
  [ "${status}" -eq 0 ]
  [[ ! -L "${DEPLOY}/scripts/feature-only.sh" ]]
}
