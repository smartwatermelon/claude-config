#!/usr/bin/env bash
# Folds local edits to ~/.claude/settings.json into a PR as the agent GitHub App (#842). See --help.
set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Every command that moves, deletes, pushes or notifies is injected; tests stub them.
GIT_BIN="${HARVEST_GIT_BIN:-git}"
GH_BIN="${HARVEST_GH_BIN:-gh}"
NOTIFY_BIN="${HARVEST_NOTIFY_BIN:-osascript}"
TOKEN_BIN="${HARVEST_TOKEN_BIN:-${HOME}/.config/bash/gh-app-token.sh}"
SECURITY_BIN="${HARVEST_SECURITY_BIN:-security}"
BUILD_BIN="${HARVEST_BUILD_BIN:-${SCRIPT_DIR}/build-machine-settings.sh}"
MV_BIN="${HARVEST_MV_BIN:-mv}"
RM_BIN="${HARVEST_RM_BIN:-rm}"
STATE_DIR="${HOME}/.local/state/claude-config"
WORK="${HARVEST_WORK_DIR:-${STATE_DIR}/harvest}"
NOTICE_FILE="${STATE_DIR}/harvest.notice"
# Seconds allowed for each credential or network step: the deploy holds its lock while this runs.
TIMEOUT="${HARVEST_TIMEOUT:-120}"
BOT_NAME="${HARVEST_AUTHOR_NAME:-smartwatermelon-agent[bot]}"
BOT_EMAIL="${HARVEST_AUTHOR_EMAIL:-345515361+smartwatermelon-agent[bot]@users.noreply.github.com}"

usage() {
  cat <<'USAGE'
Usage: harvest-user-settings.sh --live <file> --src <user-settings dir> --host <HOST>
                                --repo <owner/name> [--local <file>] [--dry-run]

Turns local edits to the live settings file into a PR that sets
user-settings/hosts/<HOST>.json (#842). claude-config-deploy.sh runs it
after a deploy that left a user-settings drift report.

  1. Overlay: the parts of the live file that differ from base.json plus
     the local file (built as install.sh builds it). Objects recurse;
     an array keeps the live items that the reference lacks.
  2. Check: build base + overlay + local and compare with live (jq -S).
     A mismatch (a base key removed, an order the build cannot make) is
     not harvestable.
  3. Refuse policy keys (hooks, env, deniedMcpServers, permissions.ask,
     permissions.deny, permissions.defaultMode): they belong in
     machine-settings/ and move by hand.
  4. Secret checks, both must pass: a shape check (env values, exact-
     command permission rules, secret-shaped strings), then gitleaks.
     Only JSON paths and check names are printed, never values.
  5. Push branch claude/harvest-settings-<host> from origin/main in a
     scratch clone (~/.local/state/claude-config/harvest), as the agent
     GitHub App, then open a PR or let the push update the open one.

The App key comes from the login Keychain through
~/.config/bash/gh-app-token.sh. With no Keychain item the harvest stops:
the helper's 1Password fallback can prompt, and nobody is there to answer.

  --local <file>  local overlay that stays on this Mac (default:
                  ~/.config/claude-code/user-settings.local.json)
  --dry-run       run every check; push nothing, open no PR

Exit: 0 PR opened or updated, or nothing to do; 1 failed;
      3 not harvestable (notified, nothing pushed); 64 usage.
USAGE
}

_log() { printf 'harvest: %s\n' "$*"; }

# Notifies once per distinct message, so a repeating refusal cannot spam.
_notify_once() {
  local msg="$1" prev=""
  prev="$(cat "${NOTICE_FILE}" 2>/dev/null || true)"
  [[ "${prev}" != "${msg}" ]] || return 0
  "${NOTIFY_BIN}" -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title "claude-config settings harvest"' \
    -e 'end run' "${msg}" >/dev/null 2>&1 || true
  mkdir -p "${STATE_DIR}" && printf '%s\n' "${msg}" >"${NOTICE_FILE}" || true
}

# Not harvestable: log, notify, exit 3. The message never holds scanned content.
_refuse() {
  _log "not harvestable: $*"
  _notify_once "Settings not harvested on ${HOST:-this Mac}: $*. See ~/.local/state/claude-config/deploy.log"
  exit 3
}

_fail() {
  _log "ERROR: $*" >&2
  exit 1
}

# _bounded <secs> <cmd...>: runs cmd, killing it and its children after secs. 124 on timeout.
_bounded() {
  local secs="$1" pid n=0 rc=0
  shift
  "$@" &
  pid=$!
  while kill -0 "${pid}" 2>/dev/null; do
    if ((n >= secs * 10)); then
      pkill -TERM -P "${pid}" 2>/dev/null || true
      kill -TERM "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
    ((n += 1))
  done
  wait "${pid}" || rc=$?
  return "${rc}"
}

LIVE=""
SRC=""
HOST=""
REPO=""
LOCAL="${HOME}/.config/claude-code/user-settings.local.json"
DRY_RUN=false
while (($# > 0)); do
  case "$1" in
    --live | --src | --host | --repo | --local)
      if [[ $# -lt 2 ]]; then
        echo "harvest: $1 needs a value" >&2
        exit 64
      fi
      case "$1" in
        --live) LIVE="$2" ;;
        --src) SRC="$2" ;;
        --host) HOST="$2" ;;
        --repo) REPO="$2" ;;
        *) LOCAL="$2" ;;
      esac
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "harvest: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [[ -z "${LIVE}" || -z "${SRC}" || -z "${HOST}" || -z "${REPO}" ]]; then
  usage >&2
  exit 64
fi
HOST="$(printf '%s' "${HOST}" | tr '[:lower:]' '[:upper:]')"
[[ "${HOST}" =~ ^[A-Z0-9][A-Z0-9-]*$ ]] || _fail "unexpected host name: ${HOST}"
[[ "${REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || _fail "unexpected repo: ${REPO}"
command -v jq >/dev/null 2>&1 || _fail "jq not found on PATH (${PATH})"
[[ -f "${SRC}/base.json" ]] || _fail "missing ${SRC}/base.json"
[[ -f "${BUILD_BIN}" ]] || _fail "missing ${BUILD_BIN}"
jq -e 'type == "object"' "${LIVE}" >/dev/null 2>&1 || _fail "${LIVE} is not a JSON object"

# arich-mac is the company machine: its settings never go to this personal, public repo.
if [[ "${HOST}" == ARICH-MAC* ]]; then
  _refuse "${HOST} is the company machine; its settings stay off this repo"
fi

BRANCH="claude/harvest-settings-$(printf '%s' "${HOST}" | tr '[:upper:]' '[:lower:]')"
URL="https://github.com/${REPO}.git"
HOST_REL="user-settings/hosts/${HOST}.json"

# ── Temp files: one dir, removed file by file (no recursive rm) ──
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/harvest.XXXXXX")" || _fail "cannot create a temp dir"
_rm_tree() {
  local d="$1" f
  [[ "${d}" == "${TMP_ROOT}" || "${d}" == "${TMP_ROOT}"/* ]] || return 0
  for f in "${d}"/* "${d}"/.[!.]*; do
    if [[ -d "${f}" && ! -L "${f}" ]]; then
      _rm_tree "${f}"
    elif [[ -e "${f}" || -L "${f}" ]]; then
      "${RM_BIN}" -f "${f}" || true
    fi
  done
  rmdir "${d}" 2>/dev/null || true
}
trap '_rm_tree "${TMP_ROOT}"' EXIT

# _build <src dir> <out>: what install.sh would build for this host.
_build() {
  mkdir -p "${2%/*}"
  MACHINE_SETTINGS_HOST="${HOST}" bash "${BUILD_BIN}" --src "$1" --out "$2" \
    --report "${2%.json}.drift.diff" --local "${LOCAL}" --host-optional >/dev/null
}

# ── 1. Overlay ──
mkdir -p "${TMP_ROOT}/ref" "${TMP_ROOT}/chk/hosts" "${TMP_ROOT}/scan"
cp "${SRC}/base.json" "${TMP_ROOT}/ref/base.json"
cp "${SRC}/base.json" "${TMP_ROOT}/chk/base.json"
_build "${TMP_ROOT}/ref" "${TMP_ROOT}/out/ref.json" || _fail "cannot build the reference from ${SRC}/base.json"

IFS= read -r -d '' OVERLAY_JQ <<'JQ' || true
  def overlay($l; $r):
    if ($l | type) == "object" and ($r | type) == "object" then
      reduce ($l | keys_unsorted[]) as $k ({};
        if ($r | has($k)) | not then .[$k] = $l[$k]
        elif $l[$k] == $r[$k] then .
        else (overlay($l[$k]; $r[$k])) as $o
          | if ($o | type) == "object" and ($o | length) == 0
              and ($l[$k] | type) == "object" then . else .[$k] = $o end
        end)
    elif ($l | type) == "array" and ($r | type) == "array" then
      [$l[] | select(. as $i | $r | index([$i]) | not)]
    else $l
    end;
  overlay($a[0]; $b[0])
JQ
overlay="$(jq -n -S --slurpfile a "${LIVE}" --slurpfile b "${TMP_ROOT}/out/ref.json" "${OVERLAY_JQ}")" ||
  _fail "cannot compute the overlay"

# ── 2. The overlay must rebuild the live file exactly ──
printf '%s\n' "${overlay}" >"${TMP_ROOT}/chk/hosts/${HOST}.json"
_build "${TMP_ROOT}/chk" "${TMP_ROOT}/out/chk.json" || _refuse "the overlay does not build (a type clash?)"
live_s="$(jq -S . "${LIVE}")" || _fail "cannot read ${LIVE}"
chk_s="$(jq -S . "${TMP_ROOT}/out/chk.json")" || _fail "cannot read the check build"
if [[ "${live_s}" != "${chk_s}" ]]; then
  # Top-level keys only: the values are not scanned yet.
  keys="$(jq -rn --slurpfile a "${LIVE}" --slurpfile b "${TMP_ROOT}/out/chk.json" '
    ($a[0]) as $l | ($b[0]) as $c
    | [($l + $c) | keys[] | select($l[.] != $c[.])
       | if test("^[A-Za-z_.@-][A-Za-z_.@-]{0,31}$") then . else "<key>" end] | join(", ")')" || keys="?"
  _refuse "an overlay cannot reproduce the live file (keys: ${keys}); a base key removed or reordered locally"
fi

# Existing host file content counts: the overlay replaces it. Same content: nothing to do.
existing="{}"
if [[ -f "${SRC}/hosts/${HOST}.json" ]]; then
  existing="$(jq -S . "${SRC}/hosts/${HOST}.json")" || _fail "cannot read ${SRC}/hosts/${HOST}.json"
fi
overlay_s="$(jq -S . <<<"${overlay}")" || _fail "cannot read the overlay"
existing_s="$(jq -S . <<<"${existing}")" || _fail "cannot read the host file"
if [[ "${overlay_s}" == "${existing_s}" ]]; then
  _log "the live file matches ${HOST_REL}; nothing to harvest"
  exit 0
fi

# ── 3 and 4. Policy keys and the shape check. Prints "<path>\t<check>"; paths only, never values. ──
IFS= read -r -d '' SHAPE_JQ <<'JQ' || true
  def secretish:
    ([scan("[A-Za-z0-9+/=_-]{20,}") | split("/")[] | select(length >= 40 or (length >= 20 and test("[0-9]")))]
      | length > 0)
    or test("://[^/@\\s]+:[^/@\\s]*@")
    or test("\\bbearer\\b"; "i")
    or test("authorization:"; "i")
    or test("(^|[\\s\"'=])-p[^\\s]")
    or test("--(auth|token|password|secret)"; "i")
    or ([scan("([A-Za-z_][A-Za-z0-9_]*)=[^\\s]") | .[0] | ascii_upcase
         | select(test("TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL")
                  or (split("_") | any(. == "KEY" or . == "APIKEY" or . == "PAT")))] | length > 0);
  def pathstr: map(if type == "number" then tostring
                   elif test("^[A-Za-z0-9_@-]{1,64}$") and (secretish | not) then .
                   else "<key>" end) | join(".");
  def rule_ok: test("^[A-Za-z0-9_.-]+$") or test("^[A-Za-z0-9_.-]+\\(.*(:\\*| \\*)\\)$");
  . as $o
  | ([["hooks"], ["env"], ["deniedMcpServers"], ["permissions", "deny"], ["permissions", "ask"],
      ["permissions", "defaultMode"]][] as $p
      | select($o | getpath($p) != null)
      | if $p == ["env"] then ($o.env | keys[] | "\(["env", .] | pathstr)\tenv-value")
        else "\($p | pathstr)\tpolicy-key" end),
    (paths(type == "string") as $p
      | select(($p | length) == 3 and $p[0] == "permissions" and (["allow", "ask", "deny"] | index([$p[1]])))
      | select($o | getpath($p) | rule_ok | not)
      | "\($p | pathstr)\trule-shape"),
    (paths(type == "string") as $p | select($o | getpath($p) | secretish)
      | "\($p | pathstr)\tsecret-shaped-string"),
    (paths as $p | select($p[-1] | type == "string") | select($p[-1] | secretish)
      | "\($p | pathstr)\tsecret-shaped-key")
JQ
if ! findings="$(jq -r "${SHAPE_JQ}" <<<"${overlay}")"; then
  _fail "the shape check could not run"
fi
if [[ -n "${findings}" ]]; then
  while IFS=$'\t' read -r path check; do
    _log "refused: ${path}: ${check}"
  done <<<"${findings}"
  findings="${findings//$'\t'/: }"
  _refuse "the shape check failed (${findings//$'\n'/; }); move these by hand"
fi

# gitleaks second. Its own empty dir, so no .gitleaks.toml beside the target can weaken it.
gitleaks_bin="${HARVEST_GITLEAKS_BIN:-$(command -v gitleaks || true)}"
if [[ -z "${gitleaks_bin}" || ! -x "${gitleaks_bin}" ]]; then
  _refuse "gitleaks is not installed, so the overlay cannot be scanned"
fi
scan_file="${TMP_ROOT}/scan/${HOST}.json"
printf '%s\n' "${overlay}" >"${scan_file}"
gl_rc=0
env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML "${gitleaks_bin}" dir --no-banner --redact \
  --log-level error --exit-code 1 "${scan_file}" >/dev/null 2>&1 || gl_rc=$?
case "${gl_rc}" in
  0) ;;
  1) _refuse "gitleaks found a secret in the overlay" ;;
  *) _refuse "gitleaks failed (exit ${gl_rc}), so the overlay is not proven clean" ;;
esac

if ${DRY_RUN}; then
  _log "dry run: would set ${HOST_REL} on ${BRANCH} and push it as the agent App; nothing pushed"
  exit 0
fi

# ── 5. Credential: the agent App, from the Keychain only ──
item="$(bash "${TOKEN_BIN}" route "${REPO}" 2>/dev/null)" || item=""
[[ "${item}" == op://* ]] || _refuse "no App credential: ${REPO} has no route in gh-app-routes.conf"
svc="${item#op://}"
svc="${svc#*/}"
acct="$(id -un)" || _fail "cannot read the user name"
# Metadata only (no -w): this never decrypts the key, so it cannot prompt.
if ! _bounded "${TIMEOUT}" "${SECURITY_BIN}" find-generic-password -s "${svc}" -a "${acct}" >/dev/null 2>&1; then
  _refuse "no App credential: no login Keychain item '${svc}' (the 1Password fallback can prompt)"
fi
if ! _bounded "${TIMEOUT}" bash "${TOKEN_BIN}" ensure "${item}" >/dev/null 2>&1; then
  _refuse "no App credential: the App token could not be minted unattended"
fi

# No global or system git config: an insteadOf, a credential helper or signing would act as Andrew.
_git() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS='' \
    "${GIT_BIN}" -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

if [[ ! -d "${WORK}/.git" ]]; then
  mkdir -p "${WORK%/*}"
  _bounded "${TIMEOUT}" _git clone --quiet --template= "${URL}" "${WORK}" || _fail "cannot clone ${URL}"
fi
origin="$(_git -C "${WORK}" remote get-url origin)" || origin=""
[[ "${origin}" == "${URL}" ]] || _fail "the scratch clone's origin is '${origin}', not ${URL}"
_bounded "${TIMEOUT}" _git -C "${WORK}" fetch --quiet --prune origin || _fail "cannot fetch ${URL}"
_git -C "${WORK}" checkout --quiet --force -B "${BRANCH}" refs/remotes/origin/main ||
  _fail "cannot check out ${BRANCH} from origin/main"

main_host="{}"
if [[ -f "${WORK}/${HOST_REL}" ]]; then
  main_host="$(jq -S . "${WORK}/${HOST_REL}")" || main_host="{}"
fi
printf '%s\n' "${main_host}" >"${TMP_ROOT}/main-host.json"
mkdir -p "${WORK}/${HOST_REL%/*}"
jq . <<<"${overlay}" >"${TMP_ROOT}/new-host.json"
cp "${TMP_ROOT}/new-host.json" "${TMP_ROOT}/stage.json"
"${MV_BIN}" -f "${TMP_ROOT}/stage.json" "${WORK}/${HOST_REL}" || _fail "cannot write ${WORK}/${HOST_REL}"
_git -C "${WORK}" add -- "${HOST_REL}" || _fail "cannot stage ${HOST_REL}"
if _git -C "${WORK}" diff --cached --quiet; then
  _log "origin/main already has this ${HOST_REL}; nothing to push"
  exit 0
fi
TITLE="chore(settings): fold ${HOST} local settings"
# The branch already carries this file: a new push would only re-run CI on the open PR.
remote_ref="refs/remotes/origin/${BRANCH}"
if _git -C "${WORK}" rev-parse --verify --quiet "${remote_ref}" >/dev/null &&
  _git -C "${WORK}" diff --cached --quiet "${remote_ref}" -- "${HOST_REL}"; then
  _log "${BRANCH} already has this ${HOST_REL}; not pushed again"
else
  _git -C "${WORK}" -c "user.name=${BOT_NAME}" -c "user.email=${BOT_EMAIL}" -c commit.gpgSign=false \
    commit --quiet -m "${TITLE}" || _fail "cannot commit in ${WORK}"
  # The App credential helper, as git-wrapper.sh sets it: only it can answer for github.com.
  helper="!$(printf '%q' "${BASH}") $(printf '%q' "${TOKEN_BIN}") git-credential $(printf '%q' "${item}")"
  _bounded "${TIMEOUT}" _git -C "${WORK}" -c credential.helper= -c "credential.helper=${helper}" \
    -c credential.useHttpPath=true -c core.askPass= \
    push --force-with-lease --quiet origin "HEAD:refs/heads/${BRANCH}" || _fail "cannot push ${BRANCH} as the App"
  _log "pushed ${BRANCH} as the agent App"
fi

# ── PR: the token goes to gh in the environment only ──
token="$(_bounded "${TIMEOUT}" bash "${TOKEN_BIN}" --item "${item}" "${REPO%%/*}" 2>/dev/null)" || token=""
[[ -n "${token}" ]] || _fail "pushed ${BRANCH}, but no App token for gh; open the PR by hand"
open="$(GH_TOKEN="${token}" _bounded "${TIMEOUT}" "${GH_BIN}" pr list -R "${REPO}" --head "${BRANCH}" \
  --state open --json url --jq '.[].url')" || _fail "pushed ${BRANCH}, but gh pr list failed"
if [[ -n "${open}" ]]; then
  _log "updated the open PR ${open}"
  exit 0
fi

body="${TMP_ROOT}/body.md"
{
  printf '%s\n\n' "Local edits to \`~/.claude/settings.json\` on ${HOST}, folded into \`${HOST_REL}\` by the deploy job (#842)."
  printf 'Fold into base.json in review if it applies to every Mac.\n\n'
  printf 'Both secret checks passed (shape check, gitleaks).\n\n```diff\n'
  diff -u --label "main:${HOST_REL}" --label "harvest:${HOST_REL}" \
    "${TMP_ROOT}/main-host.json" "${TMP_ROOT}/new-host.json" || true
  printf '```\n'
} >"${body}"
url="$(GH_TOKEN="${token}" _bounded "${TIMEOUT}" "${GH_BIN}" pr create -R "${REPO}" --head "${BRANCH}" \
  --base main --title "${TITLE}" --body-file "${body}")" || _fail "pushed ${BRANCH}, but gh pr create failed"
_log "opened ${url}"
_notify_once "Settings harvest opened a PR for ${HOST}: ${url}"
