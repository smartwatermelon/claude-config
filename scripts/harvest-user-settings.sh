#!/usr/bin/env bash
# Folds local edits to ~/.claude/settings.json into a PR as the agent GitHub App (#842). See --help.
set -euo pipefail
unset CDPATH
# An inherited repo location would beat `git -C` and point every git call at another repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

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
# Not sandbox-writable: an agent could plant a filter driver in a writable clone's .git/config.
WORK="${HARVEST_WORK_DIR:-${HOME}/.local/share/claude-config-harvest}"
NOTICE_FILE="${STATE_DIR}/harvest.notice"
# Seconds allowed for each credential or network step: the deploy holds its lock while this runs.
TIMEOUT="${HARVEST_TIMEOUT:-120}"
BOT_NAME="${HARVEST_AUTHOR_NAME:-smartwatermelon-agent[bot]}"
BOT_EMAIL="${HARVEST_AUTHOR_EMAIL:-345515361+smartwatermelon-agent[bot]@users.noreply.github.com}"

usage() {
  cat <<'USAGE'
Usage: harvest-user-settings.sh --live <file> --src <user-settings dir> --host <HOST>
                                --repo <owner/name> [--local <file>] [--built <file>]
                                [--dry-run]

Turns local edits to the live settings file into a PR that sets
user-settings/hosts/<HOST>.json and, for approved rules, the host's
group file (#842). claude-config-deploy.sh runs it
after a deploy that left a user-settings drift report.

  1. Local delta D: the parts of the live file that differ from
     <live>.built, the last build (a three-way merge, as git does).
     Objects recurse; an array keeps the live items .built lacks.
  2. Removals (a key or array item of .built missing from live): one
     that only this host's file supplies (a build of main's base +
     groups + local lacks it) is dropped from the host file in step 5.
     One that base.json, a group file or the local file supplies, or a
     type change, is not harvestable. No delta and no removal: nothing to do.
  3. Refuse policy keys (hooks, env, deniedMcpServers, permissions.ask,
     permissions.deny, permissions.defaultMode): they belong in
     machine-settings/ and move by hand.
  4. Secret checks on D, both must pass: a shape check (env values,
     secret-shaped strings), then gitleaks.
     Only JSON paths and check names are printed, never values.
  5. In a scratch clone (~/.local/share/claude-config-harvest) at
     origin/main: merge the part of D that main lacks into
     hosts/<HOST>.json (arrays add items, scalars replace), and drop
     the host-only removals. Check, by
     the build's own three-way rule, that a build of the result holds
     D; main may hold other hosts' changes, so it need not equal live.
     Fan-out: a new permissions.allow rule goes to groups/<group>.json
     instead when groups.json puts this host in exactly one group, the
     rule is an exact Bash(...) command (no *), and it matches no line
     of user-settings/host-only-rules.txt. Any doubt (no group or
     several, a missing or invalid list, a failed check) keeps it in
     the host file. If the split build fails the check, every rule
     goes back to the host file and the PR body says so.
  6. Push branch claude/harvest-settings-<host> as the agent GitHub
     App, then open a PR or let the push update the open one.

The App key comes from the login Keychain, or from the key file
~/.config/gh-app-keys/<service>.pem (GH_APP_KEY_DIR moves it), through
~/.config/bash/gh-app-token.sh. With neither the harvest stops: the
helper's 1Password fallback can prompt, and nobody is there to answer.

  --local <file>  local overlay that stays on this Mac (default:
                  ~/.config/claude-code/user-settings.local.json)
  --built <file>  the last build (default: <live>.built)
  --dry-run       run every check, folding into --src instead of
                  origin/main (nothing is fetched); push nothing

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
BUILT=""
DRY_RUN=false
while (($# > 0)); do
  case "$1" in
    --live | --src | --host | --repo | --local | --built)
      if [[ $# -lt 2 ]]; then
        echo "harvest: $1 needs a value" >&2
        exit 64
      fi
      case "$1" in
        --live) LIVE="$2" ;;
        --src) SRC="$2" ;;
        --host) HOST="$2" ;;
        --repo) REPO="$2" ;;
        --built) BUILT="$2" ;;
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
[[ -n "${BUILT}" ]] || BUILT="${LIVE}.built"
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

# Top-level keys of the JSON on stdin, names only: the values are not scanned yet.
_keys() {
  jq -r '[keys[] | if test("^[A-Za-z_.@-][A-Za-z_.@-]{0,31}$") then . else "<key>" end] | join(", ")' ||
    printf '?\n'
}

# ── 1. Local delta D: live against the last build ──
jq -e 'type == "object"' "${BUILT}" >/dev/null 2>&1 || _fail "${BUILT} is not a JSON object (no record of the last build)"
mkdir -p "${TMP_ROOT}/fold" "${TMP_ROOT}/scan"

IFS= read -r -d '' OVERLAY_JQ <<'JQ' || true
  def overlay($l; $r):
    if ($l | type) == "object" and ($r | type) == "object" then
      reduce ($l | keys_unsorted[]) as $k ({};
        if ($r | has($k)) | not then .[$k] = $l[$k]
        elif $l[$k] == $r[$k] then .
        else (overlay($l[$k]; $r[$k])) as $o
          | if (["object", "array"] | index([$o | type])) and ($o | length) == 0
              and ($l[$k] | type) == ($o | type) and ($r[$k] | type) == ($o | type) then . else .[$k] = $o end
        end)
    elif ($l | type) == "array" and ($r | type) == "array" then
      [$l[] | select(. as $i | $r | index([$i]) | not)]
    else $l
    end;
  overlay($a[0]; $b[0])
JQ
overlay="$(jq -n -S --slurpfile a "${LIVE}" --slurpfile b "${BUILT}" "${OVERLAY_JQ}")" ||
  _fail "cannot compute the local delta"
printf '%s\n' "${overlay}" >"${TMP_ROOT}/fold/delta.json"

# ── 2. Removals: [{k: key|item|type, p: path, i: item}]. A type change is refused here. ──
IFS= read -r -d '' GONE_JQ <<'JQ' || true
  def gone($b; $l; $p):
    if ($b | type) == "object" and ($l | type) == "object" then
      ($b | keys_unsorted[]) as $k
      | if ($l | has($k)) then gone($b[$k]; $l[$k]; $p + [$k]) else {k: "key", p: ($p + [$k])} end
    elif ($b | type) == "array" and ($l | type) == "array" then
      $b[] | . as $i | select(any($l[]; . == $i) | not) | {k: "item", p: $p, i: $i}
    elif (["object", "array"] | index([$b | type])) then {k: "type", p: $p}
    else empty end;
  [gone($b[0]; $l[0]; [])]
JQ
jq -n --slurpfile b "${BUILT}" --slurpfile l "${LIVE}" "${GONE_JQ}" >"${TMP_ROOT}/fold/removed.json" ||
  _fail "cannot list the local removals"
# Top-level keys under removals of kind $1 (all kinds if empty).
_removed_keys() {
  jq --arg k "$1" '[.[] | select($k == "" or .k == $k) | {(.p[0]): 0}] | add // {}' \
    "${TMP_ROOT}/fold/removed.json" | _keys
}
REFUSE_REMOVAL="a local change removes something base.json, a group file or the local file supplies"
type_keys="$(_removed_keys type)" || type_keys="?"
if [[ -n "${type_keys}" ]]; then
  _refuse "a local change removes something by changing its type (keys: ${type_keys}); move it by hand"
fi
if jq -e 'length == 0' >/dev/null <<<"${overlay}" && jq -e 'length == 0' "${TMP_ROOT}/fold/removed.json" >/dev/null; then
  _log "the live file holds no change from the last build; nothing to harvest"
  exit 0
fi

# _fold <dir>: folds D and host-only removals into <dir>'s host file; sets FOLD_NEEDED. Help step 5.
IFS= read -r -d '' APPLY_JQ <<'JQ' || true
  def apply($h; $d):
    if ($h | type) == "object" and ($d | type) == "object" then
      reduce ($d | keys_unsorted[]) as $k ($h; .[$k] = (if has($k) then apply(.[$k]; $d[$k]) else $d[$k] end))
    elif ($h | type) == "array" and ($d | type) == "array" then
      $h + [$d[] | select(. as $i | any($h[]; . == $i) | not)]
    else $d end;
  apply($h[0]; $d[0])
JQ
# Drops each removal from the host file, then any container that left empty.
IFS= read -r -d '' DROP_JQ <<'JQ' || true
  def at($v; $p): if $p == [] then $v elif ($v | type) == "object" then at($v[$p[0]]; $p[1:]) else null end;
  def haspath($v; $p):
    $p == [] or (($v | type) == "object" and ($v | has($p[0])) and haspath($v[$p[0]]; $p[1:]));
  def prune($p):
    at(.; $p) as $v
    | if $p != [] and (["object", "array"] | index([$v | type])) and ($v | length) == 0
      then delpaths([$p]) | prune($p[:-1]) else . end;
  reduce $r[0][] as $e ($h[0];
    if $e.k == "key" then (if haspath(.; $e.p) then delpaths([$e.p]) | prune($e.p[:-1]) else . end)
    elif (at(.; $e.p) | type) == "array" then setpath($e.p; [at(.; $e.p)[] | select(. != $e.i)]) | prune($e.p)
    else . end)
JQ
# Removals that a build without the host file (base + groups + local) still holds: those cannot be folded.
IFS= read -r -d '' SUPPLIED_JQ <<'JQ' || true
  def at($v; $p): if $p == [] then $v elif ($v | type) == "object" then at($v[$p[0]]; $p[1:]) else null end;
  def haspath($v; $p):
    $p == [] or (($v | type) == "object" and ($v | has($p[0])) and haspath($v[$p[0]]; $p[1:]));
  [$r[0][] | select(if .k == "key" then haspath($n[0]; .p)
                    else . as $e | (at($n[0]; $e.p) | type) == "array" and any(at($n[0]; $e.p)[]; . == $e.i) end)]
JQ
# _copy_groups <src dir> <dir>: groups.json and every groups/*.json, so builds of <dir> get the group layer.
_copy_groups() {
  local g
  [[ -f "$1/groups.json" ]] || return 0
  mkdir -p "$2/groups" || _fail "cannot create $2/groups"
  cp "$1/groups.json" "$2/groups.json" || _fail "cannot copy $1/groups.json"
  for g in "$1"/groups/*.json; do
    [[ -f "${g}" ]] || continue
    cp "${g}" "$2/groups/${g##*/}" || _fail "cannot copy ${g}"
  done
}
# ── Fan-out (help step 5) ──
# A rule starts on the host; only grep exit 1 (no risk match) moves it.
GROUP=""
GROUP_REL=""
GROUP_NOTE=""
RISK_NOTE=""
SPLIT_FALLBACK=false
HOST_CHANGED=false
GROUP_CHANGED=false
# _host_group <src dir> <log: true|false>: sets GROUP to the one group groups.json puts HOST in; else GROUP="".
_host_group() {
  local src="$1" say="$2" names n loud=false
  GROUP=""
  GROUP_REL=""
  GROUP_NOTE=""
  if [[ ! -f "${src}/groups.json" ]]; then
    GROUP_NOTE="${HOST} is in no group (no groups.json)"
  elif ! names="$(jq -r --arg h "${HOST}" \
    'to_entries[] | select((.value | type) == "array" and any(.value[]; . == $h)) | .key' "${src}/groups.json")"; then
    GROUP_NOTE="groups.json cannot be read"
    loud=true
  else
    n="$(grep -c . <<<"${names}" || true)"
    if [[ "${n}" == 0 ]]; then
      GROUP_NOTE="${HOST} is in no group"
    elif [[ "${n}" != 1 ]]; then
      GROUP_NOTE="${HOST} is in ${n} groups, not one"
    elif [[ ! "${names}" =~ ^[A-Za-z0-9_-]+$ || ! -f "${src}/groups/${names}.json" ]]; then
      GROUP_NOTE="the group of ${HOST} has a bad name or no file"
      loud=true
    fi
  fi
  if [[ -n "${GROUP_NOTE}" ]]; then
    if ${say} && ${loud}; then
      _log "ERROR: ${GROUP_NOTE}; every new rule stays in ${HOST_REL}" >&2
    elif ${say}; then
      _log "${GROUP_NOTE}; every new rule stays in ${HOST_REL}"
    fi
    return 0
  fi
  GROUP="${names}"
  GROUP_REL="user-settings/groups/${GROUP}.json"
}
# _risk_load <list>: strips the list's comments and blank lines into risk.ere. Missing, unreadable or invalid: 1.
_risk_load() {
  local list="$1" pats="${TMP_ROOT}/fold/risk.ere" rc=0
  if [[ ! -f "${list}" || ! -r "${list}" ]]; then
    RISK_NOTE="the risk list ${list##*/user-settings/} is missing or unreadable"
  elif ! tr -d '\r' <"${list}" >"${pats}.raw"; then
    RISK_NOTE="the risk list cannot be read"
  else
    # A blank line would match every rule, and a comment is not a pattern: both go.
    grep -vE '^[[:space:]]*(#|$)' "${pats}.raw" >"${pats}" || rc=$?
    if ((rc > 1)); then
      RISK_NOTE="the risk list cannot be read (grep exit ${rc})"
    elif [[ -s "${pats}" ]]; then
      # grep exits 2 on an invalid ERE; that is a broken list, never "no match".
      rc=0
      grep -Eiq -f "${pats}" </dev/null || rc=$?
      ((rc <= 1)) || RISK_NOTE="the risk list holds an invalid pattern (grep exit ${rc})"
    else
      # An emptied list is more likely a bad edit than a choice to fan out every exact rule.
      RISK_NOTE="the risk list holds no patterns"
    fi
  fi
  [[ -z "${RISK_NOTE}" ]] && return 0
  _log "ERROR: ${RISK_NOTE}; every new rule stays in ${HOST_REL}" >&2
  return 1
}
# Exact Bash(...) rules only: any other tool, a * wildcard, bare Bash or a control character stays on the host.
IFS= read -r -d '' CANDIDATE_JQ <<'JQ' || true
  (.permissions.allow // [])[]
  | select(type == "string" and (test("[[:cntrl:]]") | not) and (contains("*") | not) and test("^Bash\\(.+\\)$"))
JQ
# _split_rules <src dir>: writes group-rules.json, the need.json allow rules that go to GROUP ([] on any doubt).
_split_rules() {
  local src="$1" f="${TMP_ROOT}/fold" rule rc out
  printf '[]\n' >"${f}/group-rules.json"
  [[ -n "${GROUP}" ]] || return 0
  _risk_load "${src}/host-only-rules.txt" || return 0
  if ! jq -r "${CANDIDATE_JQ}" "${f}/need.json" >"${f}/candidates.txt"; then
    _log "ERROR: cannot list the new allow rules; every new rule stays in ${HOST_REL}" >&2
    return 0
  fi
  : >"${f}/group-rules.txt"
  while IFS= read -r rule || [[ -n "${rule}" ]]; do
    rc=1
    if [[ -s "${f}/risk.ere" ]]; then
      rc=0
      printf '%s\n' "${rule}" | grep -Eiq -f "${f}/risk.ere" || rc=$?
    fi
    case "${rc}" in
      0) ;;
      1) printf '%s\n' "${rule}" >>"${f}/group-rules.txt" ;;
      *) _log "ERROR: the risk check failed (grep exit ${rc}); that rule stays in ${HOST_REL}" >&2 ;;
    esac
  done <"${f}/candidates.txt"
  # Only rules need.json holds, so a parsing slip can never grant something new.
  if ! out="$(jq -R . "${f}/group-rules.txt" | jq -s -c --slurpfile n "${f}/need.json" \
    '[.[] | select(. as $r | ($n[0].permissions.allow // []) | index([$r]))]')"; then
    _log "ERROR: cannot list the group rules; every new rule stays in ${HOST_REL}" >&2
    return 0
  fi
  printf '%s\n' "${out}" >"${f}/group-rules.json"
}
# need.json without the group rules $g, pruning a permissions or allow it leaves empty.
IFS= read -r -d '' HOSTNEED_JQ <<'JQ' || true
  $n[0] as $n | $g[0] as $g
  | if ($g | length) == 0 then $n
    else $n | .permissions.allow -= $g
      | if (.permissions.allow | length) == 0 then del(.permissions.allow) else . end
      | if (.permissions | length) == 0 then del(.permissions) else . end
    end
JQ
# _place <mode>: new-host.json, and new-group.json with a group, from need.json; mode split or host.
_place() {
  local f="${TMP_ROOT}/fold"
  [[ "$1" == split ]] || printf '[]\n' >"${f}/group-rules.json"
  jq -n --slurpfile n "${f}/need.json" --slurpfile g "${f}/group-rules.json" "${HOSTNEED_JQ}" \
    >"${f}/host-need.json" || _fail "cannot split the local delta"
  jq -n --slurpfile h "${f}/main-host.json" --slurpfile d "${f}/host-need.json" "${APPLY_JQ}" \
    >"${f}/added-host.json" || _fail "cannot merge the local delta into the host file"
  jq -n --slurpfile h "${f}/added-host.json" --slurpfile r "${f}/removed.json" "${DROP_JQ}" \
    >"${f}/new-host.json" || _fail "cannot drop the local removals from the host file"
  HOST_CHANGED=true
  if jq -n -e --slurpfile a "${f}/main-host.json" --slurpfile b "${f}/new-host.json" '$a == $b' >/dev/null; then
    HOST_CHANGED=false
  fi
  GROUP_CHANGED=false
  [[ -n "${GROUP}" ]] || return 0
  jq 'if length == 0 then {} else {permissions: {allow: .}} end' "${f}/group-rules.json" >"${f}/group-need.json" ||
    _fail "cannot list the group rules"
  jq -n --slurpfile h "${f}/main-group.json" --slurpfile d "${f}/group-need.json" "${APPLY_JQ}" \
    >"${f}/new-group.json" || _fail "cannot merge the group rules into ${GROUP_REL}"
  if ! jq -n -e --slurpfile a "${f}/main-group.json" --slurpfile b "${f}/new-group.json" '$a == $b' >/dev/null; then
    GROUP_CHANGED=true
  fi
}
# _check <src dir>: the build's dry run on the folded files; prints its exit code.
_check() {
  local f="${TMP_ROOT}/fold" rc=0
  cp "${f}/new-host.json" "${f}/chk/hosts/${HOST}.json" || _fail "cannot copy the new host file"
  if [[ -n "${GROUP}" ]]; then
    cp "${f}/new-group.json" "${f}/chk/groups/${GROUP}.json" || _fail "cannot copy the new group file"
  fi
  # The live file and its .built, copied: the build's dry run then classifies the result.
  cp "${LIVE}" "${f}/live.json" || _fail "cannot copy ${LIVE}"
  cp "${BUILT}" "${f}/live.json.built" || _fail "cannot copy ${BUILT}"
  MACHINE_SETTINGS_HOST="${HOST}" bash "${BUILD_BIN}" --src "${f}/chk" --out "${f}/live.json" \
    --report "${f}/chk.drift.diff" --local "${LOCAL}" --host-optional --dry-run >/dev/null 2>&1 || rc=$?
  printf '%s\n' "${rc}"
}
_fold() {
  local src="$1" f="${TMP_ROOT}/fold" need keys supplied rc=0 d has_allow n_group n_host
  [[ -f "${src}/base.json" ]] || _fail "missing ${src}/base.json"
  mkdir -p "${f}/ref/hosts" "${f}/chk/hosts" "${f}/nohost" || _fail "cannot create ${f}"
  # A rule a group file supplies is not this host's to drop: one Mac must not revoke it for the group.
  for d in ref chk nohost; do
    _copy_groups "${src}" "${f}/${d}"
  done
  if [[ -f "${src}/hosts/${HOST}.json" ]]; then
    jq . "${src}/hosts/${HOST}.json" >"${f}/main-host.json" || _fail "cannot read ${src}/hosts/${HOST}.json"
  else
    printf '{}\n' >"${f}/main-host.json"
  fi
  cp "${src}/base.json" "${f}/ref/base.json" || _fail "cannot copy ${src}/base.json"
  cp "${src}/base.json" "${f}/chk/base.json" || _fail "cannot copy ${src}/base.json"
  cp "${f}/main-host.json" "${f}/ref/hosts/${HOST}.json" || _fail "cannot copy the host file"
  _build "${f}/ref" "${f}/out/ref.json" || _fail "cannot build ${src} for ${HOST}"
  cp "${src}/base.json" "${f}/nohost/base.json" || _fail "cannot copy ${src}/base.json"
  _build "${f}/nohost" "${f}/out/nohost.json" || _fail "cannot build ${src} without the host file"
  jq -n --slurpfile r "${f}/removed.json" --slurpfile n "${f}/out/nohost.json" "${SUPPLIED_JQ}" \
    >"${f}/supplied.json" || _fail "cannot check the local removals against ${src}"
  supplied="$(jq '[.[] | {(.p[0]): 0}] | add // {}' "${f}/supplied.json" | _keys)" || supplied="?"
  if [[ -n "${supplied}" ]]; then
    _refuse "${REFUSE_REMOVAL} (keys: ${supplied}); removals move by hand"
  fi
  need="$(jq -n -S --slurpfile a "${f}/delta.json" --slurpfile b "${f}/out/ref.json" "${OVERLAY_JQ}")" ||
    _fail "cannot compare the local delta with ${src}"
  printf '%s\n' "${need}" >"${f}/need.json"
  printf '[]\n' >"${f}/group-rules.json"
  # The split runs only for new allow rules; any other key stays in the host file.
  has_allow=false
  if jq -e '(.permissions.allow // []) | length > 0' "${f}/need.json" >/dev/null; then
    has_allow=true
  fi
  _host_group "${src}" "${has_allow}"
  if [[ -n "${GROUP}" ]]; then
    jq . "${src}/groups/${GROUP}.json" >"${f}/main-group.json" || _fail "cannot read ${src}/groups/${GROUP}.json"
    ! ${has_allow} || _split_rules "${src}"
  fi
  _place split
  FOLD_NEEDED=true
  if ! ${HOST_CHANGED} && ! ${GROUP_CHANGED}; then
    FOLD_NEEDED=false
    return 0
  fi
  rc="$(_check)"
  if [[ "${rc}" != 0 ]] && jq -e 'length > 0' "${f}/group-rules.json" >/dev/null; then
    # The split must never cost a fold: put every rule back in the host file and check that.
    SPLIT_FALLBACK=true
    _log "the build check failed (exit ${rc}) with rules in ${GROUP_REL}; every new rule stays in ${HOST_REL}"
    _place host
    rc="$(_check)"
  fi
  if ${has_allow}; then
    n_group="$(jq 'length' "${f}/group-rules.json")" || n_group="?"
    n_host="$(jq '(.permissions.allow // []) | length' "${f}/host-need.json")" || n_host="?"
    _log "new allow rules: ${n_group} to ${GROUP_REL:-no group file}, ${n_host} to ${HOST_REL}"
  fi
  keys="$(_keys <<<"${need}")"
  case "${rc}" in
    0) ;;
    2) _refuse "the folded host file does not hold every local change (keys: ${keys}); an order or type the build cannot make" ;;
    *) _refuse "the folded host file does not build (exit ${rc}; a type clash?)" ;;
  esac
}

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
  # Exact allow rules are harvested; rule text may be public.
  # secretish and gitleaks guard secrets in it.
  . as $o
  | ([["hooks"], ["env"], ["deniedMcpServers"], ["permissions", "deny"], ["permissions", "ask"],
      ["permissions", "defaultMode"]][] as $p
      | select($o | getpath($p) != null)
      | if $p == ["env"] then ($o.env | keys[] | "\(["env", .] | pathstr)\tenv-value")
        else "\($p | pathstr)\tpolicy-key" end),
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

# A dry run fetches nothing: it folds into --src, not origin/main.
if ${DRY_RUN}; then
  _fold "${SRC}"
  if ! ${FOLD_NEEDED}; then
    _log "dry run: ${SRC} already holds every local change; nothing to harvest"
  else
    paths=""
    ! ${HOST_CHANGED} || paths="${HOST_REL}"
    ! ${GROUP_CHANGED} || paths="${paths:+${paths} and }${GROUP_REL}"
    _log "dry run: would set ${paths} on ${BRANCH} and push it as the agent App; nothing pushed"
  fi
  exit 0
fi

# ── 5. Credential: the agent App, from the Keychain or the helper's key file, never 1Password ──
item="$(bash "${TOKEN_BIN}" route "${REPO}" 2>/dev/null)" || item=""
[[ "${item}" == op://* ]] || _refuse "no App credential: ${REPO} has no route in gh-app-routes.conf"
svc="${item#op://}"
svc="${svc#*/}"
acct="$(id -un)" || _fail "cannot read the user name"
# The helper's key file, for a cron host with no unlocked Keychain. The helper checks it is safe.
key_file="${GH_APP_KEY_DIR:-${HOME}/.config/gh-app-keys}/${svc}.pem"
# Metadata only (no -w): this never decrypts the key, so it cannot prompt.
if ! _bounded "${TIMEOUT}" "${SECURITY_BIN}" find-generic-password -s "${svc}" -a "${acct}" >/dev/null 2>&1 \
  && ! [[ -f "${key_file}" && -r "${key_file}" && ! -L "${key_file}" ]]; then
  _refuse "no App credential: no login Keychain item '${svc}' and no key file ${key_file} (the 1Password fallback can prompt)"
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
# The push URLs too, after any pushurl or pushInsteadOf in the clone's own config (as git-wrapper.sh checks).
push_urls="$(_git -C "${WORK}" remote get-url --push --all origin)" || push_urls=""
[[ -n "${push_urls}" ]] || _fail "cannot read the scratch clone's push URL"
while IFS= read -r u; do
  [[ "${u}" == "${URL}" ]] || _fail "the scratch clone pushes to '${u}', not ${URL}"
done <<<"${push_urls}"
_bounded "${TIMEOUT}" _git -C "${WORK}" fetch --quiet --prune origin || _fail "cannot fetch ${URL}"
_git -C "${WORK}" checkout --quiet --force -B "${BRANCH}" refs/remotes/origin/main ||
  _fail "cannot check out ${BRANCH} from origin/main"

_fold "${WORK}/user-settings"
if ! ${FOLD_NEEDED}; then
  _log "origin/main already holds every local change; nothing to push"
  exit 0
fi
# _stage <folded file> <repo path>: writes the file into the scratch clone and stages it.
_stage() {
  mkdir -p "${WORK}/${2%/*}"
  cp "$1" "${TMP_ROOT}/stage.json" || _fail "cannot copy $1"
  "${MV_BIN}" -f "${TMP_ROOT}/stage.json" "${WORK}/$2" || _fail "cannot write ${WORK}/$2"
  _git -C "${WORK}" add -- "$2" || _fail "cannot stage $2"
}
! ${HOST_CHANGED} || _stage "${TMP_ROOT}/fold/new-host.json" "${HOST_REL}"
! ${GROUP_CHANGED} || _stage "${TMP_ROOT}/fold/new-group.json" "${GROUP_REL}"
# The branch check compares every file a fold can set, changed or not, so a stale group change is seen.
FOLD_PATHS=("${HOST_REL}")
[[ -z "${GROUP_REL}" ]] || FOLD_PATHS+=("${GROUP_REL}")
if _git -C "${WORK}" diff --cached --quiet; then
  _log "origin/main already has these files (${FOLD_PATHS[*]}); nothing to push"
  exit 0
fi
TITLE="chore(settings): fold ${HOST} local settings"
# The branch already carries this file: a new push would only re-run CI on the open PR.
remote_ref="refs/remotes/origin/${BRANCH}"
if _git -C "${WORK}" rev-parse --verify --quiet "${remote_ref}" >/dev/null &&
  _git -C "${WORK}" diff --cached --quiet "${remote_ref}" -- "${FOLD_PATHS[@]}"; then
  _log "${BRANCH} already has these files (${FOLD_PATHS[*]}); not pushed again"
else
  # GIT_AUTHOR_* and GIT_COMMITTER_* outrank user.name, and a caller may have set them: set all four.
  GIT_AUTHOR_NAME="${BOT_NAME}" GIT_AUTHOR_EMAIL="${BOT_EMAIL}" GIT_COMMITTER_NAME="${BOT_NAME}" \
    GIT_COMMITTER_EMAIL="${BOT_EMAIL}" _git -C "${WORK}" -c "user.name=${BOT_NAME}" -c "user.email=${BOT_EMAIL}" \
    -c commit.gpgSign=false commit --quiet -m "${TITLE}" || _fail "cannot commit in ${WORK}"
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

# _rule_list <JSON array file>: one rule per line in a fence, or "None." for an empty list.
_rule_list() {
  if jq -e 'length > 0' "$1" >/dev/null 2>&1; then
    printf '~~~text\n'
    jq -r '.[]' "$1" || printf '(cannot list the rules; see the diff)\n'
    printf '~~~\n\n'
  else
    printf 'None.\n\n'
  fi
}
fold="${TMP_ROOT}/fold"
jq '.permissions.allow // []' "${fold}/host-need.json" >"${fold}/host-rules.json" || printf '[]\n' >"${fold}/host-rules.json"
if [[ "${GROUP}" == personal ]]; then
  group_title="Personal Macs (${GROUP_REL#user-settings/})"
elif [[ -n "${GROUP}" ]]; then
  group_title="Macs in group ${GROUP} (${GROUP_REL#user-settings/})"
else
  group_title="Personal Macs"
fi
body="${TMP_ROOT}/body.md"
{
  printf '%s\n\n' "Local edits to \`~/.claude/settings.json\` on ${HOST}, folded by the deploy job (#842)."
  printf 'Each rule below is a grant: merging this PR allows it on the Macs its heading names.\n\n'
  printf '### %s\n\n' "${group_title}"
  if [[ -z "${GROUP}" ]]; then
    printf 'None: %s, so every new rule stays on this Mac.\n\n' "${GROUP_NOTE:-${HOST} is in no group}"
  else
    _rule_list "${fold}/group-rules.json"
  fi
  printf '### This Mac only (%s)\n\n' "${HOST_REL#user-settings/}"
  _rule_list "${fold}/host-rules.json"
  if ${SPLIT_FALLBACK}; then
    printf 'The build check failed with the rules split across files, so every new rule stays in %s.\n\n' "\`${HOST_REL}\`"
  fi
  if [[ -n "${RISK_NOTE}" ]]; then
    printf 'Every new rule stays on this Mac: %s.\n\n' "${RISK_NOTE}"
  fi
  printf 'Fold into base.json in review if it applies to every Mac.\n\n'
  printf 'Both secret checks passed (shape check, gitleaks).\n\n```diff\n'
  if ${GROUP_CHANGED}; then
    diff -u --label "main:${GROUP_REL}" --label "harvest:${GROUP_REL}" \
      "${fold}/main-group.json" "${fold}/new-group.json" || true
  fi
  if ${HOST_CHANGED}; then
    diff -u --label "main:${HOST_REL}" --label "harvest:${HOST_REL}" \
      "${fold}/main-host.json" "${fold}/new-host.json" || true
  fi
  printf '```\n'
} >"${body}"
# The rule lists are grants: an open PR's body must list what its branch now holds.
if [[ -n "${open}" ]]; then
  GH_TOKEN="${token}" _bounded "${TIMEOUT}" "${GH_BIN}" pr edit "${open}" -R "${REPO}" --body-file "${body}" \
    >/dev/null || _fail "pushed ${BRANCH}, but gh pr edit failed; the body of ${open} may be stale"
  _log "updated the open PR ${open} and its body"
  exit 0
fi
url="$(GH_TOKEN="${token}" _bounded "${TIMEOUT}" "${GH_BIN}" pr create -R "${REPO}" --head "${BRANCH}" \
  --base main --title "${TITLE}" --body-file "${body}")" || _fail "pushed ${BRANCH}, but gh pr create failed"
_log "opened ${url}"
_notify_once "Settings harvest opened a PR for ${HOST}: ${url}"
