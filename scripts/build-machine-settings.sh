#!/usr/bin/env bash
# Builds machine-settings.json from machine-settings/ (dev-env#249). Run by install.sh in the deploy clone only. See --help.
set -euo pipefail
unset CDPATH

MV_BIN="${MACHINE_SETTINGS_MV_BIN:-mv}"
RM_BIN="${MACHINE_SETTINGS_RM_BIN:-rm}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/../machine-settings"
OUT="${MACHINE_SETTINGS_OUT:-${HOME}/.config/claude-code/machine-settings.json}"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: build-machine-settings.sh [--src <dir>] [--out <file>] [--dry-run]

Builds ~/.config/claude-code/machine-settings.json, which claude-wrapper
passes to Claude Code with --settings (smartwatermelon/dev-env#249).
install.sh runs it from the deploy clone only, never from a --dev
checkout: that checkout is agent-writable, and a build from it would
let an agent change its own sandbox.

  1. Read the host name (hostname -s, upper-case). No
     <src>/hosts/<HOST>.json: do nothing, leave any output as it is.
  2. Merge <src>/base.json and the host file: objects merge deep, host
     arrays append to base arrays, a host scalar replaces the base's.
     An object or array clashing with another type fails.
  3. Fill the placeholders. An unknown ${NAME} fails.
       ${HOME}            $HOME
       ${TMPDIR}          getconf DARWIN_USER_TEMP_DIR, no trailing slash
                          (not $TMPDIR: the sandbox and launchd differ)
       ${GDRIVE_HANDOFF}  ~/Library/CloudStorage/GoogleDrive-*/My Drive/Claude Handoff,
                          in ~/ form; exactly one match or the build fails
     ${TMPDIR} and ${GDRIVE_HANDOFF} are looked up only when used.
  4. Check: a JSON object with no "${" left.
  5. Compare the live output with <out>.built, the record of the last
     build (jq -S equality), and with the new build:
       - no output, or no .built yet: write it. The first build saves
         the old file once as <out>.bak-<date>-pre-build.
       - live equals the new build: write nothing, record .built. A hand
         edit that has since landed in the repo resolves this way.
       - live equals .built: write the new build if it differs.
       - live differs from both: DRIFT, a hand edit the repo lacks.
         Write nothing, save a report, exit 2. Fold the change into
         machine-settings/ via a PR; the next deploy clears it.
     A write is a temp file beside the output, chmod 600, mv. After it,
     .built records exactly what was written (same way).
  A failure leaves the old output in place.

Options:
  --src <dir>   source directory (default: machine-settings/ in this repo)
  --out <file>  output (default: ~/.config/claude-code/machine-settings.json)
  --dry-run     build and check; print what would change; write nothing

Environment (tests and one-off checks):
  MACHINE_SETTINGS_OUT     output file, as --out
  MACHINE_SETTINGS_HOST    host name instead of hostname -s
  MACHINE_SETTINGS_TMPDIR  ${TMPDIR} value instead of getconf's
  MACHINE_SETTINGS_DRIFT_REPORT  drift report (default:
                           ~/.local/state/claude-config/machine-settings.drift.diff;
                           read-only for people, never read by the build)
  MACHINE_SETTINGS_MV_BIN, MACHINE_SETTINGS_RM_BIN  injected mv and rm

Exit: 0 built, unchanged or no host file; 1 failed; 2 drift; 64 usage.
USAGE
}

_log() { printf 'build-machine-settings: %s\n' "$*"; }
_fail() {
  printf 'build-machine-settings: ERROR: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --src)
      [[ $# -ge 2 ]] || {
        echo "build-machine-settings: --src needs a value" >&2
        exit 64
      }
      SRC="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || {
        echo "build-machine-settings: --out needs a value" >&2
        exit 64
      }
      OUT="$2"
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
      echo "build-machine-settings: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || _fail "jq not found on PATH (${PATH})"
[[ -n "${HOME:-}" && "${HOME}" == /* ]] || _fail "HOME is unset or not absolute"

# ── 1. Host ─────────────────────────────────────────────
# Not scutil LocalHostName: the Claude sandbox returns a default for it.
host="${MACHINE_SETTINGS_HOST:-}"
if [[ -z "${host}" ]]; then
  host="$(hostname -s 2>/dev/null)" || host=""
fi
host="$(printf '%s' "${host}" | tr '[:lower:]' '[:upper:]')"
[[ -n "${host}" ]] || _fail "cannot read the host name"
[[ "${host}" =~ ^[A-Z0-9][A-Z0-9-]*$ ]] || _fail "unexpected host name: ${host}"

base_file="${SRC}/base.json"
host_file="${SRC}/hosts/${host}.json"
if [[ ! -f "${host_file}" ]]; then
  _log "no ${host_file}; ${OUT} left as it is"
  exit 0
fi
[[ -f "${base_file}" ]] || _fail "missing ${base_file}"

# ── 2. Merge ────────────────────────────────────────────
# A type clash fails: neither side is safe to pick for a sandbox setting.
merged="$(jq -n --slurpfile b "${base_file}" --slurpfile h "${host_file}" '
  def merge($a; $b; $path):
    if ($a | type) == "object" and ($b | type) == "object" then
      reduce ($b | keys_unsorted[]) as $k ($a;
        .[$k] = (if has($k) then merge(.[$k]; $b[$k]; $path + [$k]) else $b[$k] end))
    elif ($a | type) == "array" and ($b | type) == "array" then $a + $b
    elif ($a | type) == ($b | type) and (["object", "array"] | index([$a | type]) | not) then $b
    else error("type clash at \($path | map(tostring) | join(".")): base \($a | type), host \($b | type)")
    end;
  if ($b | length) != 1 or ($h | length) != 1 then error("each source file must hold one JSON value")
  elif ($b[0] | type) != "object" or ($h[0] | type) != "object" then error("base and host files must be JSON objects")
  else merge($b[0]; $h[0]; []) end
')" || _fail "cannot merge ${base_file} and ${host_file}"

# ── 3. Placeholders ─────────────────────────────────────
KNOWN_PLACEHOLDERS=(HOME TMPDIR GDRIVE_HANDOFF)

used="$(jq -r '[.. | strings, (objects | keys[])] | map(scan("\\$\\{([^}]*)\\}")[0]) | unique[]' <<<"${merged}")" ||
  _fail "cannot list placeholders"

unknown=()
uses_tmpdir=false
uses_gdrive=false
while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  case "${name}" in
    HOME) ;;
    TMPDIR) uses_tmpdir=true ;;
    GDRIVE_HANDOFF) uses_gdrive=true ;;
    *) unknown+=("${name}") ;;
  esac
done <<<"${used}"
if ((${#unknown[@]} > 0)); then
  _fail "unknown placeholder(s): ${unknown[*]} (known: ${KNOWN_PLACEHOLDERS[*]})"
fi

val_tmpdir=""
if ${uses_tmpdir}; then
  val_tmpdir="${MACHINE_SETTINGS_TMPDIR:-}"
  if [[ -z "${val_tmpdir}" ]]; then
    val_tmpdir="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" || val_tmpdir=""
  fi
  val_tmpdir="${val_tmpdir%/}"
  [[ "${val_tmpdir}" == /* ]] || _fail "cannot find the per-user temp dir for \${TMPDIR}"
fi

val_gdrive=""
if ${uses_gdrive}; then
  matches=()
  for d in "${HOME}"/Library/CloudStorage/GoogleDrive-*/"My Drive/Claude Handoff"; do
    if [[ -d "${d}" ]]; then
      matches+=("${d}")
    fi
  done
  if ((${#matches[@]} != 1)); then
    _fail "\${GDRIVE_HANDOFF}: want exactly one ${HOME}/Library/CloudStorage/GoogleDrive-*/My Drive/Claude Handoff, found ${#matches[@]}"
  fi
  # The ~/ form, as the sandbox's allowWrite entries are written.
  tilde='~'
  val_gdrive="${tilde}/${matches[0]#"${HOME}/"}"
fi

# Values go in as jq strings, not regex replacement text. Keys are filled too.
built="$(jq --arg home "${HOME}" --arg tmpdir "${val_tmpdir}" --arg gdrive "${val_gdrive}" '
  def fill:
    gsub("\\$\\{HOME\\}"; $home)
    | gsub("\\$\\{TMPDIR\\}"; $tmpdir)
    | gsub("\\$\\{GDRIVE_HANDOFF\\}"; $gdrive);
  walk(if type == "string" then fill
       elif type == "object" then with_entries(.key |= fill)
       else . end)
' <<<"${merged}")" || _fail "cannot fill placeholders"

# ── 4. Check ────────────────────────────────────────────
_check() {
  jq -e 'type == "object" and ([.. | strings, (objects | keys[])] | any(contains("${")) | not)' \
    "$1" >/dev/null 2>&1
}

# ── 5. Write ────────────────────────────────────────────
out_dir="$(dirname "${OUT}")"
BUILT="${OUT}.built"
REPORT="${MACHINE_SETTINGS_DRIFT_REPORT:-${HOME}/.local/state/claude-config/machine-settings.drift.diff}"

tmp=""
tmp_rec=""
_cleanup() {
  [[ -z "${tmp}" ]] || "${RM_BIN}" -f "${tmp}" || true
  [[ -z "${tmp_rec}" ]] || "${RM_BIN}" -f "${tmp_rec}" || true
}
trap _cleanup EXIT

# Same settings, ignoring key order and whitespace. Unreadable or invalid JSON is never equal.
_same() {
  local a b
  a="$(jq -S . "$1" 2>/dev/null)" || return 1
  b="$(jq -S . "$2" 2>/dev/null)" || return 1
  [[ "${a}" == "${b}" ]]
}

# Sets CASE to new, same, first, normal or drift; --help explains each.
_classify() {
  if [[ ! -f "${OUT}" ]]; then
    CASE=new
  elif _same "${OUT}" "$1"; then
    CASE=same
  elif [[ ! -f "${BUILT}" ]]; then
    CASE=first
  elif _same "${OUT}" "${BUILT}"; then
    CASE=normal
  else
    CASE=drift
  fi
}

DRIFT_LINE="DRIFT: ${OUT} was edited by hand since the last build, so it was not overwritten."
DRIFT_LINE+=" Fold the change into claude-config machine-settings/ via a PR; the next deploy then clears it."
DRIFT_LINE+=" Diff: ${REPORT}"

# Writes the drift report: jq -S of .built and of the live file, and a unified diff of the two.
_write_report() {
  local dir="${REPORT%/*}" base="${REPORT%.diff}"
  mkdir -p "${dir}" || return 1
  jq -S . "${BUILT}" >"${base}.built.json" 2>/dev/null || cp "${BUILT}" "${base}.built.json" || return 1
  jq -S . "${OUT}" >"${base}.live.json" 2>/dev/null || cp "${OUT}" "${base}.live.json" || return 1
  local rc=0 now
  now="$(date '+%Y-%m-%d %H:%M:%S %Z')" || now="unknown time"
  {
    printf '# %s\n' "${DRIFT_LINE}"
    printf '# Written %s. --- is the last build (%s), +++ is the live file (%s).\n' \
      "${now}" "${BUILT}" "${OUT}"
    diff -u --label "${BUILT}" --label "${OUT}" "${base}.built.json" "${base}.live.json" || rc=$?
  } >"${REPORT}"
  ((rc <= 1))
}

# Records exactly what was built as ${BUILT}: temp file, mode 600, mv.
_record_built() {
  if [[ -f "${BUILT}" ]] && cmp -s "$1" "${BUILT}"; then
    return 0
  fi
  tmp_rec="$(mktemp "${out_dir}/.machine-settings.built.XXXXXX")" || return 1
  cp "$1" "${tmp_rec}" && chmod 600 "${tmp_rec}" && "${MV_BIN}" -f "${tmp_rec}" "${BUILT}" || return 1
  tmp_rec=""
}

if ${DRY_RUN}; then
  tmp="$(mktemp)" || _fail "cannot create a temp file"
  printf '%s\n' "${built}" >"${tmp}" || _fail "cannot write ${tmp}"
  _check "${tmp}" || _fail "built file failed the check (not an object, or a \${ is left)"
  _classify "${tmp}"
  case "${CASE}" in
    drift)
      printf 'build-machine-settings: dry run: %s\n' "${DRIFT_LINE}" >&2
      exit 2
      ;;
    same) _log "dry run: ${OUT} already matches ${host}; would record ${BUILT}" ;;
    *) _log "dry run: would write ${OUT} for ${host} (${CASE})" ;;
  esac
  exit 0
fi

mkdir -p "${out_dir}" || _fail "cannot create ${out_dir}"
tmp="$(mktemp "${out_dir}/.machine-settings.XXXXXX")" || _fail "cannot create a temp file in ${out_dir}"

printf '%s\n' "${built}" >"${tmp}" || _fail "cannot write ${tmp}"
chmod 600 "${tmp}" || _fail "cannot chmod ${tmp}"
_check "${tmp}" || _fail "built file failed the check (not an object, or a \${ is left); ${OUT} left as it is"

_classify "${tmp}"

if [[ "${CASE}" == drift ]]; then
  _write_report || _fail "${DRIFT_LINE} (and the report could not be written)"
  printf 'build-machine-settings: %s\n' "${DRIFT_LINE}" >&2
  exit 2
fi

# No drift now: a report left from an earlier run is stale.
if [[ -e "${REPORT}" ]]; then
  "${RM_BIN}" -f "${REPORT}" "${REPORT%.diff}.built.json" "${REPORT%.diff}.live.json" ||
    _log "could not remove the stale drift report ${REPORT}"
fi

if [[ "${CASE}" == same ]]; then
  chmod 600 "${OUT}" || _fail "cannot chmod ${OUT}"
  _record_built "${tmp}" || _fail "cannot record ${BUILT}"
  _log "${OUT} already matches ${host}"
  exit 0
fi

# Once per machine: keep the hand-made file the first build replaces.
if [[ -f "${OUT}" ]]; then
  have_backup=false
  for b in "${OUT}".bak-*-pre-build; do
    if [[ -e "${b}" ]]; then
      have_backup=true
      break
    fi
  done
  if ! ${have_backup}; then
    backup="${OUT}.bak-$(date +%Y%m%d)-pre-build"
    cp -p "${OUT}" "${backup}" || _fail "cannot back up ${OUT} to ${backup}"
    _log "saved the pre-build file as ${backup}"
  fi
fi

"${MV_BIN}" -f "${tmp}" "${OUT}" || _fail "cannot move ${tmp} over ${OUT}"
tmp=""
_record_built "${OUT}" || _fail "wrote ${OUT}, but cannot record ${BUILT}; the next run records it"
_log "wrote ${OUT} for ${host}"
