#!/usr/bin/env bash
# Tests for scripts/claude-config-deploy.sh (#453).
# Each case: HOME in a mktemp -d, a bare origin, stub install.sh, launchctl and osascript.

set -euo pipefail
unset CDPATH

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/claude-config-deploy.sh"
ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOT_TMP}"' EXIT

# Keep the caller's git config (templates, signing, hooks) out of the fixtures.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

pass=0
fail=0
ok() {
  echo "  PASS: $1"
  ((pass += 1))
}
bad() {
  echo "  FAIL: $1"
  ((fail += 1))
}
# check_eq <desc> <want> <command...>: the command's stdout must equal want.
check_eq() {
  local desc="$1" want="$2" got
  shift 2
  got="$("$@" 2>/dev/null || true)"
  if [[ "${got}" == "${want}" ]]; then ok "${desc}"; else bad "${desc} (got '${got}', want '${want}')"; fi
}
check() { # check <desc> <command...>
  local desc="$1"
  shift
  if "$@"; then ok "${desc}"; else bad "${desc}"; fi
}

gitq() { git -c user.name=T -c user.email=t@t -c commit.gpgSign=false "$@"; }

# fresh: a new temp world. Sets T, HOME, ORIGIN, CLONE, DEV, LOG, MARKER.
fresh() {
  T="$(mktemp -d "${ROOT_TMP}/case.XXXXXX")"
  export HOME="${T}/home"
  mkdir -p "${HOME}/.claude" "${T}/bin"
  ORIGIN="${T}/origin.git"
  CLONE="${HOME}/.local/share/claude-config"
  DEV="${HOME}/Developer/claude-config"
  LOG="${HOME}/.local/state/claude-config/deploy.log"
  MARKER="${HOME}/.local/state/claude-config/dev-mode"
  PLIST="${HOME}/Library/LaunchAgents/com.smartwatermelon.claude-config-deploy.plist"

  local seed="${T}/seed"
  mkdir -p "${seed}/hooks" "${seed}/scripts"
  gitq init -q -b main "${seed}"
  cp "${SCRIPT}" "${seed}/scripts/claude-config-deploy.sh"
  # The stub install.sh records its arguments and links the canary hook to
  # its own checkout, which is what the real --sync does for every file.
  cat >"${seed}/install.sh" <<'EOF'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")" && pwd)"
printf '%s %s\n' "${dir}" "$*" >>"${STUB_INSTALL_LOG}"
mkdir -p "${HOME}/.claude/hooks"
ln -sfn "${dir}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
exit "${STUB_INSTALL_RC:-0}"
EOF
  printf '#!/usr/bin/env bash\n' >"${seed}/hooks/run-review.sh"
  printf 'v1\n' >"${seed}/CLAUDE.md"
  chmod +x "${seed}/install.sh" "${seed}/hooks/run-review.sh" "${seed}/scripts/claude-config-deploy.sh"
  gitq -C "${seed}" add -A
  gitq -C "${seed}" commit -q -m v1
  gitq clone -q --bare "${seed}" "${ORIGIN}"
  gitq -C "${seed}" remote add origin "${ORIGIN}"

  cat >"${T}/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_LAUNCHCTL_LOG}"
[[ "$1" == print ]] && exit "${STUB_LOADED_RC:-113}"
exit 0
EOF
  cat >"${T}/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_NOTIFY_LOG}"
EOF
  chmod +x "${T}/bin/launchctl" "${T}/bin/osascript"

  export STUB_INSTALL_LOG="${T}/install.log" STUB_LAUNCHCTL_LOG="${T}/launchctl.log"
  export STUB_NOTIFY_LOG="${T}/notify.log"
  export CLAUDE_CONFIG_DEPLOY_URL="${ORIGIN}"
  export CLAUDE_CONFIG_LAUNCHCTL_BIN="${T}/bin/launchctl"
  export CLAUDE_CONFIG_OSASCRIPT_BIN="${T}/bin/osascript"
  unset STUB_INSTALL_RC STUB_LOADED_RC CLAUDE_CONFIG_DEV_TTL_HOURS
  touch "${STUB_INSTALL_LOG}" "${STUB_LAUNCHCTL_LOG}" "${STUB_NOTIFY_LOG}"
}

make_clone() { gitq clone -q --branch main "${ORIGIN}" "${CLONE}"; }

# Push a new commit to origin; prints its sha.
advance_origin() {
  local seed="${T}/seed"
  printf '%s\n' "$1" >"${seed}/CLAUDE.md"
  gitq -C "${seed}" commit -q -am "$1"
  gitq -C "${seed}" push -q origin main
  gitq -C "${seed}" rev-parse HEAD
}

run_deploy() { # sets rc and out
  rc=0
  out="$("${SCRIPT}" "$@" 2>&1)" || rc=$?
}
run_clone_script() {
  rc=0
  out="$("${CLONE}/scripts/claude-config-deploy.sh" "$@" 2>&1)" || rc=$?
}

lines() {
  local n
  n="$(wc -l <"$1")"
  printf '%s' "${n// /}"
}
UID_N="$(id -u)"
head_of() { git -C "$1" rev-parse HEAD; }

echo "=== claude-config-deploy.sh ==="

# --- usage ------------------------------------------------------------------
fresh
run_deploy --bogus
check "unknown argument exits 64" test "${rc}" -eq 64

# --- deploy: refusals -------------------------------------------------------
fresh
run_deploy deploy
check "no clone: refuses with exit 2" test "${rc}" -eq 2
check "no clone: names bootstrap" grep -q "bootstrap" "${LOG}"

fresh
make_clone
printf 'local edit\n' >"${CLONE}/CLAUDE.md"
run_deploy deploy --scheduled
check "dirty clone: refuses with exit 2" test "${rc}" -eq 2
check "dirty clone: the edit is kept" grep -qx 'local edit' "${CLONE}/CLAUDE.md"
check "dirty clone: the log names the file" grep -q "CLAUDE.md" "${LOG}"
check_eq "dirty clone: install.sh did not run" 0 lines "${STUB_INSTALL_LOG}"
check_eq "dirty clone: one notification" 1 lines "${STUB_NOTIFY_LOG}"
run_deploy deploy --scheduled
check "dirty clone again: still refuses" test "${rc}" -eq 2
check_eq "dirty clone again: no repeat notification" 1 lines "${STUB_NOTIFY_LOG}"

fresh
make_clone
gitq -C "${CLONE}" switch -q -c side
run_deploy deploy --scheduled
check "clone off main: refuses with exit 2" test "${rc}" -eq 2
check_eq "clone off main: branch is left as is" side git -C "${CLONE}" symbolic-ref --short HEAD

fresh
make_clone
printf 'mine\n' >"${CLONE}/local.txt"
gitq -C "${CLONE}" add local.txt
gitq -C "${CLONE}" commit -q -m local
local_head="$(head_of "${CLONE}")"
advance_origin v2 >/dev/null
run_deploy deploy --scheduled
check "diverged clone: refuses with exit 2" test "${rc}" -eq 2
check_eq "diverged clone: local commit is kept" "${local_head}" head_of "${CLONE}"
check "diverged clone: log says it cannot fast-forward" grep -q "fast-forward" "${LOG}"

# --- deploy: the normal paths ----------------------------------------------
fresh
make_clone
run_deploy deploy
check "manual deploy: exit 0" test "${rc}" -eq 0
check "manual deploy: runs the clone's install.sh --sync" grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"
check_eq "manual deploy: ~/.claude links into the clone" \
  "${CLONE}/hooks/run-review.sh" readlink "${HOME}/.claude/hooks/run-review.sh"
check "manual deploy: prints what it did" grep -q "install.sh --sync" <<<"${out}"

run_deploy deploy --scheduled
check "scheduled, nothing new: exit 0" test "${rc}" -eq 0
check_eq "scheduled, nothing new: install.sh not re-run" 1 lines "${STUB_INSTALL_LOG}"
check "scheduled, nothing new: logs that it is up to date" grep -q "up to date" "${LOG}"
check "scheduled: nothing on stdout (launchd logs it already)" test -z "${out}"

new_sha="$(advance_origin v2)"
run_deploy deploy --scheduled
check "scheduled, origin moved: exit 0" test "${rc}" -eq 0
check_eq "scheduled, origin moved: clone fast-forwarded" "${new_sha}" head_of "${CLONE}"
check_eq "scheduled, origin moved: install.sh re-run" 2 lines "${STUB_INSTALL_LOG}"
check "scheduled, origin moved: logs the deploy" grep -q "deployed" "${LOG}"

fresh
make_clone
STUB_INSTALL_RC=1 run_deploy deploy
check "install.sh failure: exit 1" test "${rc}" -eq 1
check_eq "install.sh failure: notifies" 1 lines "${STUB_NOTIFY_LOG}"

fresh
make_clone
git -C "${CLONE}" remote set-url origin "${T}/no-such-origin.git"
run_deploy deploy --scheduled
check "fetch failure: exit 1" test "${rc}" -eq 1
check "fetch failure: logged" grep -q "fetch" "${LOG}"

# --- lock --------------------------------------------------------------------
fresh
make_clone
mkdir -p "${HOME}/.local/state/claude-config"
ln -s "$$" "${HOME}/.local/state/claude-config/deploy.lock"
run_deploy deploy --scheduled
check "lock held by a live process: exit 3" test "${rc}" -eq 3
check "lock held: the other run's lock is kept" test -L "${HOME}/.local/state/claude-config/deploy.lock"

fresh
make_clone
mkdir -p "${HOME}/.local/state/claude-config"
# A pid far above any real one: no such process.
ln -s 99999999 "${HOME}/.local/state/claude-config/deploy.lock"
run_deploy deploy --scheduled
check "stale lock: the run proceeds" test "${rc}" -eq 0
check "stale lock: removed after the run" test ! -L "${HOME}/.local/state/claude-config/deploy.lock"

# --- dev mode ------------------------------------------------------------------
dev_mode() { # dev_mode <seconds ago>
  mkdir -p "${DEV}/hooks" "${HOME}/.claude/hooks" "${MARKER%/*}"
  printf '#!/usr/bin/env bash\n' >"${DEV}/hooks/run-review.sh"
  ln -sfn "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
  local now
  now="$(date +%s)"
  printf 'path=%s\nsince=%s\n' "${DEV}" "$((now - $1))" >"${MARKER}"
}

fresh
make_clone
dev_mode 60
new_sha="$(advance_origin v2)"
run_deploy deploy --scheduled
check "fresh dev mode, scheduled: exit 0" test "${rc}" -eq 0
check_eq "fresh dev mode, scheduled: install.sh not run" 0 lines "${STUB_INSTALL_LOG}"
check_eq "fresh dev mode, scheduled: links stay on the working checkout" \
  "${DEV}/hooks/run-review.sh" readlink "${HOME}/.claude/hooks/run-review.sh"
check_eq "fresh dev mode, scheduled: clone still fast-forwarded" "${new_sha}" head_of "${CLONE}"
check "fresh dev mode, scheduled: logged as dev mode" grep -q "dev mode" "${LOG}"

fresh
make_clone
dev_mode $((13 * 3600))
run_deploy deploy --scheduled
check "expired dev mode, scheduled: install.sh runs" grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"
check_eq "expired dev mode, scheduled: links back on the clone" \
  "${CLONE}/hooks/run-review.sh" readlink "${HOME}/.claude/hooks/run-review.sh"
n_notify="$(lines "${STUB_NOTIFY_LOG}")"
check "expired dev mode, scheduled: notifies" test "${n_notify}" -ge 1

fresh
make_clone
dev_mode 60
export CLAUDE_CONFIG_DEV_TTL_HOURS=0
run_deploy deploy --scheduled
check "dev TTL override 0: ends dev mode at once" grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"
unset CLAUDE_CONFIG_DEV_TTL_HOURS

fresh
make_clone
dev_mode 60
run_deploy deploy
check "fresh dev mode, manual deploy: ends it" grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"

fresh
make_clone
dev_mode 60
"${SCRIPT}" deploy >/dev/null 2>&1 || true
: >"${STUB_INSTALL_LOG}"
# An old install.sh run from the working checkout: links moved, no marker.
mkdir -p "${DEV}/hooks"
ln -sfn "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
rm -f "${MARKER}"
run_deploy deploy --scheduled
check "links off the clone with no marker: relinked by the scheduled run" \
  grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"
check "links off the clone with no marker: logged" grep -q "not linked to the deploy clone" "${LOG}"

# --- bootstrap ---------------------------------------------------------------
fresh
run_deploy bootstrap
check "bootstrap: exit 0" test "${rc}" -eq 0
check_eq "bootstrap: clone created on main" main git -C "${CLONE}" symbolic-ref --short HEAD
check "bootstrap: clone's install.sh --sync ran" grep -qx "${CLONE} --sync" "${STUB_INSTALL_LOG}"
check "bootstrap: continues as the clone's own copy" grep -q "${CLONE}/scripts/claude-config-deploy.sh" <<<"${out}"
check "bootstrap: plist written" test -f "${PLIST}"
check "bootstrap: plist runs the clone's script" grep -q "<string>${CLONE}/scripts/claude-config-deploy.sh</string>" "${PLIST}"
check "bootstrap: plist runs scheduled" grep -q "<string>--scheduled</string>" "${PLIST}"
check "bootstrap: plist interval is 600s" grep -q "<integer>600</integer>" "${PLIST}"
check "bootstrap: plist label" grep -q "<string>com.smartwatermelon.claude-config-deploy</string>" "${PLIST}"
check "bootstrap: plist parses" python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "${PLIST}"
check_eq "bootstrap: command link to the clone's script" \
  "${CLONE}/scripts/claude-config-deploy.sh" readlink "${HOME}/.local/bin/claude-config-deploy"
check "bootstrap: agent bootstrapped into the gui domain" \
  grep -qx "bootstrap gui/${UID_N} ${PLIST}" "${STUB_LAUNCHCTL_LOG}"

# Re-run: agent already loaded, plist unchanged -> no reload.
before="$(grep -c '^bootstrap ' "${STUB_LAUNCHCTL_LOG}")"
STUB_LOADED_RC=0 run_clone_script bootstrap
check "bootstrap re-run: exit 0" test "${rc}" -eq 0
after="$(grep -c '^bootstrap ' "${STUB_LAUNCHCTL_LOG}")"
check "bootstrap re-run: agent not reloaded" test "${after}" -eq "${before}"

fresh
mkdir -p "${CLONE}"
printf 'precious\n' >"${CLONE}/notes.txt"
run_deploy bootstrap
check "bootstrap, clone path is not a git repo: refuses with exit 2" test "${rc}" -eq 2
check "bootstrap, clone path is not a git repo: its files are kept" grep -qx precious "${CLONE}/notes.txt"

fresh
mkdir -p "${HOME}/.local/bin"
printf 'mine\n' >"${HOME}/.local/bin/claude-config-deploy"
run_deploy bootstrap
check "bootstrap, command path is a regular file: refuses with exit 2" test "${rc}" -eq 2
check "bootstrap, command path is a regular file: kept" grep -qx mine "${HOME}/.local/bin/claude-config-deploy"

# The user's global hooks and templates must not run in the clone: one that edits a tracked file stops every deploy.
fresh
mkdir -p "${T}/ghooks" "${T}/gtemplate/hooks"
for h in post-checkout post-merge; do
  printf '#!/usr/bin/env bash\necho %s >>"%s/hook-ran"\n' "${h}" "${T}" >"${T}/ghooks/${h}"
  cp "${T}/ghooks/${h}" "${T}/gtemplate/hooks/${h}"
done
chmod +x "${T}"/ghooks/* "${T}"/gtemplate/hooks/*
printf '[core]\n\thooksPath = %s\n\tfsmonitor = false\n[init]\n\ttemplateDir = %s\n' \
  "${T}/ghooks" "${T}/gtemplate" >"${T}/gitconfig"
GIT_CONFIG_GLOBAL="${T}/gitconfig" "${SCRIPT}" bootstrap >/dev/null 2>&1 || true
advance_origin v2 >/dev/null
GIT_CONFIG_GLOBAL="${T}/gitconfig" "${CLONE}/scripts/claude-config-deploy.sh" deploy >/dev/null 2>&1 || true
check "global hooks: none ran in the clone during clone or fast-forward" test ! -e "${T}/hook-ran"
check "global hooks: no template hooks copied into the clone" test ! -e "${CLONE}/.git/hooks/post-checkout"

# --- uninstall -----------------------------------------------------------------
fresh
"${SCRIPT}" bootstrap >/dev/null 2>&1
run_clone_script uninstall
check "uninstall: exit 0" test "${rc}" -eq 0
check "uninstall: agent booted out" grep -qx "bootout gui/${UID_N}/com.smartwatermelon.claude-config-deploy" "${STUB_LAUNCHCTL_LOG}"
check "uninstall: plist removed" test ! -e "${PLIST}"
check "uninstall: command link removed" test ! -L "${HOME}/.local/bin/claude-config-deploy"
check "uninstall: clone kept" test -d "${CLONE}/.git"

# --- status --------------------------------------------------------------------
fresh
"${SCRIPT}" bootstrap >/dev/null 2>&1
run_clone_script status
check "status: exit 0" test "${rc}" -eq 0
check "status: names the clone" grep -q "${CLONE}" <<<"${out}"
check "status: says deployed" grep -qi "deployed" <<<"${out}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
