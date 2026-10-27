#!/usr/bin/env bash
# Keeps ~/.claude on origin/main via the deploy clone (#453).
# Usage: see usage() below, or --help.

set -euo pipefail
unset CDPATH

# Fixed paths, not XDG: launchd passes none of the shell's exports. install.sh uses the same ones.
LABEL="com.smartwatermelon.claude-config-deploy"
CLONE="${HOME}/.local/share/claude-config"
DEV_CHECKOUT="${HOME}/Developer/claude-config"
DEPLOY_DIR="${HOME}/.claude"
STATE_DIR="${HOME}/.local/state/claude-config"
LOG_FILE="${STATE_DIR}/deploy.log"
LOCK="${STATE_DIR}/deploy.lock"
PROBLEM_FILE="${STATE_DIR}/deploy.problem"
# Epoch of the last run that ended in a good state. The status line and SessionStart flag it when old.
OK_FILE="${STATE_DIR}/deploy.ok"
DEV_MARKER="${STATE_DIR}/dev-mode"
CANARY="hooks/run-review.sh"
URL="${CLAUDE_CONFIG_DEPLOY_URL:-https://github.com/smartwatermelon/claude-config.git}"
DEV_TTL_HOURS="${CLAUDE_CONFIG_DEV_TTL_HOURS:-12}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
AGENT_LOG="${HOME}/.local/state/${LABEL}.log"
COMMAND_LINK="${HOME}/.local/bin/claude-config-deploy"
CLONE_SCRIPT="${CLONE}/scripts/claude-config-deploy.sh"
INTERVAL=600

# Every command that deletes, moves, overwrites or changes launchd state is injected; tests stub them.
GIT_BIN="${CLAUDE_CONFIG_GIT_BIN:-git}"
RM_BIN="${CLAUDE_CONFIG_RM_BIN:-rm}"
LN_BIN="${CLAUDE_CONFIG_LN_BIN:-ln}"
MV_BIN="${CLAUDE_CONFIG_MV_BIN:-mv}"
LAUNCHCTL_BIN="${CLAUDE_CONFIG_LAUNCHCTL_BIN:-launchctl}"
OSASCRIPT_BIN="${CLAUDE_CONFIG_OSASCRIPT_BIN:-osascript}"

QUIET=false
LOCK_HELD=false

usage() {
  cat <<EOF
Usage: claude-config-deploy [command]

  deploy               Fetch origin, fast-forward ${CLONE} to origin/main,
                       and run its install.sh --sync. Ends dev mode. (default)
  deploy --scheduled   The LaunchAgent's run: relinks only when main moved or
                       ~/.claude is off the clone; keeps dev mode for ${DEV_TTL_HOURS}h.
  bootstrap            Clone (if needed), deploy, and install the LaunchAgent.
  uninstall            Remove the LaunchAgent and the command link. Keeps the clone.
  status               Show the clone, the link mode, the agent, and the last good run.

Exit: 0 ok, 1 failed, 2 refused (clone changed or diverged), 3 another run holds the lock, 64 usage.
Log: ${LOG_FILE}
EOF
}

_log() {
  local stamp
  stamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  mkdir -p "${STATE_DIR}"
  printf '%s %s\n' "${stamp}" "$*" >>"${LOG_FILE}" || true
  if ! ${QUIET}; then
    printf '%s\n' "$*"
  fi
}

_notify() {
  "${OSASCRIPT_BIN}" -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "claude-config deploy"' \
    -e 'end run' "$1" >/dev/null 2>&1 || true
}

# Logs every time; notifies only when the problem differs from the last run's, so a 10-minute loop cannot spam.
_problem() {
  local key="$1" msg="$2" prev=""
  _log "${msg}"
  prev="$(cat "${PROBLEM_FILE}" 2>/dev/null || true)"
  if [[ "${prev}" != "${key}" ]]; then
    _notify "${msg}"
    printf '%s\n' "${key}" >"${PROBLEM_FILE}" || true
  fi
}

_clear_problem() {
  if [[ -e "${PROBLEM_FILE}" ]]; then
    "${RM_BIN}" -f "${PROBLEM_FILE}" || true
  fi
}

# Atomic (temp file, then mv). A failed write only logs: a missing stamp reads as stale, never as fine.
_mark_ok() {
  local tmp now
  now="$(date +%s)"
  mkdir -p "${STATE_DIR}"
  if ! tmp="$(mktemp "${OK_FILE}.XXXXXX" 2>/dev/null)"; then
    _log "could not create a temp file for ${OK_FILE}"
    return 0
  fi
  if printf '%s\n' "${now}" >"${tmp}" && "${MV_BIN}" -f "${tmp}" "${OK_FILE}"; then
    return 0
  fi
  _log "could not write ${OK_FILE}"
  "${RM_BIN}" -f "${tmp}" || true
}

_fmt_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"
}

# The lock is a symlink naming the holder's pid: ln -s is atomic, and readlink tells a live holder from a stale one.
_acquire_lock() {
  local holder
  mkdir -p "${STATE_DIR}"
  if "${LN_BIN}" -s "$$" "${LOCK}" 2>/dev/null; then
    LOCK_HELD=true
    return 0
  fi
  holder="$(readlink "${LOCK}" 2>/dev/null || true)"
  if [[ "${holder}" =~ ^[0-9]+$ ]] && kill -0 "${holder}" 2>/dev/null; then
    return 1
  fi
  _log "removing a stale lock (pid ${holder:-unknown} is not running)"
  "${RM_BIN}" -f "${LOCK}" || return 1
  if "${LN_BIN}" -s "$$" "${LOCK}" 2>/dev/null; then
    LOCK_HELD=true
    return 0
  fi
  return 1
}

_release_lock() {
  if ${LOCK_HELD} && [[ "$(readlink "${LOCK}" 2>/dev/null || true)" == "$$" ]]; then
    "${RM_BIN}" -f "${LOCK}" || true
  fi
  LOCK_HELD=false
}

# No hooks or fsmonitor in the clone: the global post-checkout hook edits .gitignore, which would stop every deploy.
NO_HOOKS=(-c core.hooksPath=/dev/null -c core.fsmonitor=false)
_git() { GIT_TERMINAL_PROMPT=0 "${GIT_BIN}" "${NO_HOOKS[@]}" -C "${CLONE}" "$@"; }

_link_target() { readlink "${DEPLOY_DIR}/${CANARY}" 2>/dev/null || true; }

# Sets DEV_PATH and DEV_SINCE from the marker install.sh --dev writes; both empty when there is none.
_read_marker() {
  local line
  DEV_PATH=""
  DEV_SINCE=""
  [[ -f "${DEV_MARKER}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      path=*) DEV_PATH="${line#path=}" ;;
      since=*) DEV_SINCE="${line#since=}" ;;
      *) ;;
    esac
  done <"${DEV_MARKER}"
}

# Runs the clone's own install.sh, a new process, so it is the version just fetched.
_run_install() {
  local rc=0
  _log "running ${CLONE}/install.sh --sync"
  if ${QUIET}; then
    "${CLONE}/install.sh" --sync >>"${LOG_FILE}" 2>&1 || rc=$?
  else
    "${CLONE}/install.sh" --sync 2>&1 | tee -a "${LOG_FILE}" || rc=$?
  fi
  return "${rc}"
}

# deploy_once <scheduled: true|false>. Holds the lock for the whole run.
deploy_once() {
  local scheduled="$1" branch dirty fetch_out old new merge_out target at_clone=false moved=false
  local rc=0 now age ttl from upto
  if ! _acquire_lock; then
    _log "another deploy holds ${LOCK}; skipping"
    return 3
  fi

  if [[ ! -e "${CLONE}/.git" ]]; then
    _problem no-clone "No deploy clone at ${CLONE}. Run: ${DEV_CHECKOUT}/scripts/claude-config-deploy.sh bootstrap"
    return 2
  fi

  branch="$(_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "${branch}" != "main" ]]; then
    _problem off-main "Refused: the deploy clone is on '${branch:-a detached HEAD}', not main. Left as is: ${CLONE}"
    return 2
  fi

  if ! dirty="$(_git status --porcelain --untracked-files=no 2>&1)"; then
    _problem status-failed "git status failed in ${CLONE}: ${dirty}"
    return 1
  fi
  if [[ -n "${dirty}" ]]; then
    _problem dirty "Refused: the deploy clone has local changes. Nothing was changed. Inspect: git -C ${CLONE} diff"
    _log "changed in the clone: ${dirty//$'\n'/; }"
    return 2
  fi

  # lowSpeed* aborts a stalled transfer; launchd would otherwise wait on it until the next interval.
  if ! fetch_out="$(_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch --quiet origin 2>&1)"; then
    _log "fetch failed (offline, or inside the Claude Code sandbox?); will retry: ${fetch_out}"
    return 1
  fi

  old="$(_git rev-parse HEAD)"
  if ! new="$(_git rev-parse --verify --quiet refs/remotes/origin/main)"; then
    _problem no-origin-main "origin has no main branch after fetch in ${CLONE}"
    return 1
  fi

  if [[ "${old}" != "${new}" ]]; then
    if ! _git merge-base --is-ancestor "${old}" "${new}"; then
      _problem diverged "Refused: clone main ${old:0:7} cannot fast-forward to origin/main ${new:0:7} (local commits). Left as is: ${CLONE}"
      return 2
    fi
    if ! merge_out="$(_git merge --ff-only --quiet "${new}" 2>&1)"; then
      _problem merge-failed "Refused: fast-forward to ${new:0:7} failed in ${CLONE}: ${merge_out}"
      return 2
    fi
    moved=true
    _log "fast-forwarded ${CLONE} ${old:0:7}..${new:0:7}"
  fi

  target="$(_link_target)"
  [[ "${target}" == "${CLONE}/${CANARY}" ]] && at_clone=true
  _read_marker

  if ${scheduled}; then
    if ! ${at_clone} && [[ -n "${DEV_PATH}" ]]; then
      now="$(date +%s)"
      ttl=$((DEV_TTL_HOURS * 3600))
      age=-1
      [[ "${DEV_SINCE}" =~ ^[0-9]+$ ]] && age=$((now - DEV_SINCE))
      if ((age >= 0 && age < ttl)); then
        from="$(_fmt_epoch "${DEV_SINCE}")"
        upto="$(_fmt_epoch $((DEV_SINCE + ttl)))"
        _log "dev mode since ${from}: ${DEPLOY_DIR} runs ${DEV_PATH}; kept until ${upto}; install skipped"
        _clear_problem
        _mark_ok
        return 0
      fi
      _log "dev mode (${DEV_PATH}) is past its ${DEV_TTL_HOURS}h window; ending it"
      _notify "Dev mode ended: ~/.claude runs origin/main again"
    elif ! ${at_clone}; then
      _log "${DEPLOY_DIR} is not linked to the deploy clone (${CANARY} -> ${target:-missing}); relinking"
    elif ! ${moved} && [[ -z "${DEV_PATH}" ]]; then
      _log "up to date at ${new:0:7}"
      _clear_problem
      _mark_ok
      return 0
    fi
  fi

  _run_install || rc=$?
  if ((rc != 0)); then
    _problem install-failed "install.sh --sync failed (exit ${rc}) at ${new:0:7}. See ${LOG_FILE}"
    return 1
  fi
  if ${moved}; then
    _log "deployed ${new:0:7} (was ${old:0:7})"
  else
    _log "deployed ${new:0:7}; ~/.claude linked to ${CLONE}"
  fi
  _clear_problem
  _mark_ok
  return 0
}

_plist_xml() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${CLONE_SCRIPT}</string>
        <string>deploy</string>
        <string>--scheduled</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>${AGENT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${AGENT_LOG}</string>
</dict>
</plist>
EOF
}

DOMAIN="gui/$(id -u)"

# Idempotent: rewrites the plist only when it differs, and reloads only when it changed or is not loaded.
install_agent() {
  local tmp changed=true domain="${DOMAIN}"
  mkdir -p "${COMMAND_LINK%/*}" "${PLIST%/*}"

  if [[ "$(readlink "${COMMAND_LINK}" 2>/dev/null || true)" == "${CLONE_SCRIPT}" ]]; then
    _log "command link already correct: ${COMMAND_LINK} -> ${CLONE_SCRIPT}"
  else
    "${LN_BIN}" -sfn "${CLONE_SCRIPT}" "${COMMAND_LINK}" || return 1
    _log "linked ${COMMAND_LINK} -> ${CLONE_SCRIPT}"
  fi

  tmp="$(mktemp "${PLIST}.XXXXXX")" || return 1
  _plist_xml >"${tmp}"
  if [[ -f "${PLIST}" ]] && cmp -s "${tmp}" "${PLIST}"; then
    "${RM_BIN}" -f "${tmp}"
    changed=false
    _log "plist unchanged: ${PLIST}"
  else
    "${MV_BIN}" -f "${tmp}" "${PLIST}" || return 1
    _log "wrote ${PLIST} (runs ${CLONE_SCRIPT} deploy --scheduled every ${INTERVAL}s)"
  fi

  if ! ${changed} && "${LAUNCHCTL_BIN}" print "${domain}/${LABEL}" >/dev/null 2>&1; then
    _log "LaunchAgent ${LABEL} already loaded"
    return 0
  fi
  "${LAUNCHCTL_BIN}" bootout "${domain}/${LABEL}" >/dev/null 2>&1 || true
  if ! "${LAUNCHCTL_BIN}" bootstrap "${domain}" "${PLIST}"; then
    _log "launchctl bootstrap ${domain} ${PLIST} failed"
    return 1
  fi
  _log "loaded LaunchAgent ${LABEL} into ${domain}"
}

_physical() { (cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")") || true; }

bootstrap() {
  local self clone_self url rc=0 target short
  self="$(_physical "${BASH_SOURCE[0]}")"

  # Checked before anything changes, so a refusal leaves the machine as it was.
  if [[ -e "${COMMAND_LINK}" && ! -L "${COMMAND_LINK}" ]]; then
    _log "Refused: ${COMMAND_LINK} is a regular file, not a link. Move it aside and re-run."
    return 2
  fi
  if [[ -e "${CLONE}" && ! -e "${CLONE}/.git" ]]; then
    _log "Refused: ${CLONE} exists but is not a git clone. Left as is; move it aside and re-run."
    return 2
  fi

  if [[ ! -e "${CLONE}" ]]; then
    _log "cloning ${URL} (main) into ${CLONE}"
    mkdir -p "${CLONE%/*}"
    GIT_TERMINAL_PROMPT=0 "${GIT_BIN}" "${NO_HOOKS[@]}" -c init.templateDir= clone --template= --quiet \
      --branch main --single-branch "${URL}" "${CLONE}" || return 1
  else
    url="$(_git remote get-url origin 2>/dev/null || true)"
    _log "deploy clone exists: ${CLONE} (origin ${url:-none})"
    [[ "${url}" == "${URL}" ]] || _log "note: origin is not ${URL}; left as is"
  fi
  # Also in the clone's own config, so install.sh's git calls and a manual git there skip them too.
  _git config core.hooksPath /dev/null || return 1
  _git config core.fsmonitor false || return 1

  # The rest runs as the clone's copy, so a working checkout on a feature branch cannot shape the deploy.
  clone_self="$(_physical "${CLONE_SCRIPT}")"
  if [[ "${self}" != "${clone_self}" ]]; then
    if [[ ! -x "${CLONE_SCRIPT}" ]]; then
      _log "the clone has no executable ${CLONE_SCRIPT}; is origin/main older than #453?"
      return 1
    fi
    _log "continuing as ${CLONE_SCRIPT}"
    exec "${CLONE_SCRIPT}" bootstrap
  fi
  _log "bootstrap running from ${self}"

  deploy_once false || rc=$?
  _release_lock
  if ((rc != 0)); then
    _log "bootstrap stopped: deploy exited ${rc}. Fix the cause above, then re-run."
    return "${rc}"
  fi
  install_agent || return 1

  target="$(_link_target)"
  short="$(_git rev-parse --short HEAD)"
  _log ""
  _log "Done. ${DEPLOY_DIR}/${CANARY} -> ${target}"
  _log "  clone:  ${CLONE} at ${short}"
  _log "  agent:  ${PLIST} (every ${INTERVAL}s; log ${LOG_FILE})"
  _log "  deploy now: claude-config-deploy    dev mode: ${DEV_CHECKOUT}/install.sh --dev"
}

uninstall() {
  local domain="${DOMAIN}"
  if "${LAUNCHCTL_BIN}" bootout "${domain}/${LABEL}" >/dev/null 2>&1; then
    _log "booted out ${domain}/${LABEL}"
  else
    _log "${LABEL} was not loaded"
  fi
  if [[ -f "${PLIST}" ]]; then
    "${RM_BIN}" -f "${PLIST}" && _log "removed ${PLIST}"
  fi
  if [[ "$(readlink "${COMMAND_LINK}" 2>/dev/null || true)" == "${CLONE_SCRIPT}" ]]; then
    "${RM_BIN}" -f "${COMMAND_LINK}" && _log "removed ${COMMAND_LINK}"
  elif [[ -e "${COMMAND_LINK}" || -L "${COMMAND_LINK}" ]]; then
    _log "left ${COMMAND_LINK}: it does not point at ${CLONE_SCRIPT}"
  fi
  _log "Kept ${CLONE} and the ~/.claude links. Nothing redeploys now; claude-config-deploy is gone."
  _log "Working-tree mode again: move ${CLONE} aside, then run ${DEV_CHECKOUT}/install.sh --sync"
}

status() {
  local target head behind="" since ok_at=""
  target="$(_link_target)"
  _read_marker
  if [[ -e "${CLONE}/.git" ]]; then
    head="$(_git log -1 --format='%h %s' 2>/dev/null || true)"
    behind="$(_git rev-list --count HEAD..refs/remotes/origin/main 2>/dev/null || true)"
    printf 'clone:  %s at %s (%s behind origin/main as of the last fetch)\n' "${CLONE}" "${head}" "${behind:-?}"
  else
    printf 'clone:  none at %s (run bootstrap)\n' "${CLONE}"
  fi
  if [[ "${target}" == "${CLONE}/${CANARY}" ]]; then
    printf 'mode:   deployed (~/.claude -> %s)\n' "${CLONE}"
  elif [[ -n "${DEV_PATH}" ]]; then
    since="$(_fmt_epoch "${DEV_SINCE:-0}")"
    printf 'mode:   DEV since %s (~/.claude -> %s)\n' "${since}" "${DEV_PATH}"
  else
    printf 'mode:   not linked to the clone (%s -> %s)\n' "${CANARY}" "${target:-missing}"
  fi
  if "${LAUNCHCTL_BIN}" print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    printf 'agent:  %s loaded\n' "${LABEL}"
  else
    printf 'agent:  %s not loaded\n' "${LABEL}"
  fi
  if [[ -f "${OK_FILE}" ]]; then
    read -r ok_at <"${OK_FILE}" || true
  fi
  if [[ "${ok_at}" =~ ^[0-9]+$ ]]; then
    since="$(_fmt_epoch "${ok_at}")"
    printf 'last ok: %s (last deploy run that ended in a good state)\n' "${since}"
  else
    printf 'last ok: never (no good run recorded in %s)\n' "${OK_FILE}"
  fi
  if [[ -f "${LOG_FILE}" ]]; then
    printf 'log:    %s (last lines)\n' "${LOG_FILE}"
    tail -n 5 "${LOG_FILE}" | sed 's/^/        /'
  fi
}

# Everything runs from main, so bash has parsed the whole file before a fast-forward rewrites it.
main() {
  local cmd="${1:-deploy}" scheduled=false rc=0
  [[ $# -gt 0 ]] && shift
  trap _release_lock EXIT
  case "${cmd}" in
    deploy)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --scheduled) scheduled=true ;;
          *)
            usage >&2
            return 64
            ;;
        esac
        shift
      done
      ${scheduled} && QUIET=true
      deploy_once "${scheduled}" || rc=$?
      return "${rc}"
      ;;
    bootstrap | uninstall | status)
      if [[ $# -gt 0 ]]; then
        usage >&2
        return 64
      fi
      case "${cmd}" in
        bootstrap) bootstrap || rc=$? ;;
        uninstall) uninstall || rc=$? ;;
        *) status || rc=$? ;;
      esac
      return "${rc}"
      ;;
    -h | --help | help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 64
      ;;
  esac
}

main "$@"
exit $?
