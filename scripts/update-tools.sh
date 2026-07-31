#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/claude-config/scripts/update-tools.sh
# Called by _claude_update() in bash profile.
# Maintains symlink health, updates submodules, and audits ~/.claude/.
# Exit 0 always — must not break the update flow.

if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf '[WARN]  update-tools.sh requires Bash 5+, found %s. Skipping.\n' "${BASH_VERSION}" >&2
  exit 0
fi

trap 'exit 0' ERR

# ── Args ────────────────────────────────────────────────
_LEARN=false
for arg in "$@"; do
  case "${arg}" in
    --learn) _LEARN=true ;;
    *) ;;
  esac
done

# ── Constants ───────────────────────────────────────────
REPO_DIR="${HOME}/Developer/claude-config"
DEPLOY_DIR="${HOME}/.claude"
KNOWN_RUNTIME_FILE="${REPO_DIR}/scripts/known-runtime.txt"

# ── Formatting helpers ──────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

# ============================================================================
# 1. SYMLINK REPAIR
# ============================================================================

_info "Repairing symlinks..."

if [[ -x "${REPO_DIR}/install.sh" ]]; then
  "${REPO_DIR}/install.sh" --repair
else
  _warn "install.sh not found or not executable at ${REPO_DIR}/install.sh"
fi

# ============================================================================
# 2. SUBMODULE UPDATES
# ============================================================================

_info "Updating submodules..."

if git -C "${REPO_DIR}" submodule status --quiet 2>/dev/null; then
  git -C "${REPO_DIR}" submodule sync
  git -C "${REPO_DIR}" submodule update --remote --merge
  _ok "Submodules updated"
else
  _ok "No submodules to update"
fi

# ============================================================================
# 3. AUDIT — categorize depth-1 entries in ~/.claude/
# ============================================================================

_info "Auditing ${DEPLOY_DIR}/..."

# Directories containing symlinked repo files (not symlinks themselves)
_REPO_MANAGED_DIRS=()
mapfile -t _tracked_files < <(git -C "${REPO_DIR}" ls-files 2>/dev/null || true)
for file in "${_tracked_files[@]}"; do
  dir="${file%%/*}"
  # Only add top-level dirs, skip top-level files
  [[ "${dir}" != "${file}" ]] || continue
  local_found=false
  for existing in "${_REPO_MANAGED_DIRS[@]+"${_REPO_MANAGED_DIRS[@]}"}"; do
    if [[ "${existing}" == "${dir}" ]]; then
      local_found=true
      break
    fi
  done
  "${local_found}" || _REPO_MANAGED_DIRS+=("${dir}")
done

# Files and directories that Claude Code manages at runtime.
# Loaded from a data file (not hardcoded) so new entries can be accepted
# with `update-tools.sh --learn` instead of a code edit. See known-runtime.txt.
_KNOWN_RUNTIME=()
if [[ -f "${KNOWN_RUNTIME_FILE}" ]]; then
  while IFS= read -r _line; do
    # Strip comments and blank lines
    _line="${_line%%#*}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -n "${_line}" ]] && _KNOWN_RUNTIME+=("${_line}")
  done < "${KNOWN_RUNTIME_FILE}"
else
  _warn "known-runtime.txt not found at ${KNOWN_RUNTIME_FILE}"
fi

_is_known_runtime() {
  local name="$1"

  # Match *.jsonl files (Claude Code log files)
  case "${name}" in
    *.jsonl) return 0 ;;
    *) ;;
  esac

  local entry
  for entry in "${_KNOWN_RUNTIME[@]}"; do
    if [[ "${name}" == "${entry}" ]]; then
      return 0
    fi
  done

  return 1
}

symlinked_count=0
runtime_count=0
unknown_count=0
unknown_items=()

for entry in "${DEPLOY_DIR}"/*  "${DEPLOY_DIR}"/.*; do
  basename="$(basename "${entry}")"

  # Skip . and ..
  case "${basename}" in
    .|..) continue ;;
    *) ;;
  esac

  # Skip if the glob didn't match anything
  [[ -e "${entry}" || -L "${entry}" ]] || continue

  # Check if it's a repo-managed directory (contains symlinked files)
  _is_repo_managed=false
  for rdir in "${_REPO_MANAGED_DIRS[@]+"${_REPO_MANAGED_DIRS[@]}"}"; do
    if [[ "${basename}" == "${rdir}" ]]; then
      _is_repo_managed=true
      break
    fi
  done

  if [[ -L "${entry}" ]]; then
    symlinked_count=$((symlinked_count + 1))
  elif "${_is_repo_managed}"; then
    symlinked_count=$((symlinked_count + 1))
  elif _is_known_runtime "${basename}"; then
    runtime_count=$((runtime_count + 1))
  else
    unknown_count=$((unknown_count + 1))
    unknown_items+=("${entry}")
  fi
done

# ── Audit report ────────────────────────────────────────
echo ""
echo "───────────────────────────────────────────────────────"
echo " ~/.claude/ Audit Report"
echo "───────────────────────────────────────────────────────"
_ok "Symlinked (repo-managed): ${symlinked_count}"
_ok "Known runtime (Claude Code): ${runtime_count}"

if [[ "${unknown_count}" -gt 0 ]]; then
  _warn "Unknown entries: ${unknown_count}"
  for item in "${unknown_items[@]}"; do
    _warn "  ${item}"
  done
  echo ""
  if "${_LEARN}"; then
    _new_entries=()
    for item in "${unknown_items[@]}"; do
      _b="$(basename "${item}")"
      _dup=false
      for existing in "${_KNOWN_RUNTIME[@]+"${_KNOWN_RUNTIME[@]}"}"; do
        if [[ "${_b}" == "${existing}" ]]; then
          _dup=true
          break
        fi
      done
      "${_dup}" || _new_entries+=("${_b}")
    done

    if [[ "${#_new_entries[@]}" -eq 0 ]]; then
      _ok "No new entries to learn (already recorded)"
    elif printf '%s\n' "${_new_entries[@]}" >> "${KNOWN_RUNTIME_FILE}"; then
      _ok "Added ${#_new_entries[@]} entries to $(basename "${KNOWN_RUNTIME_FILE}")"
      _info "Review and commit: git -C ${REPO_DIR} diff scripts/known-runtime.txt"
    else
      _warn "Failed to write to ${KNOWN_RUNTIME_FILE}"
    fi
  else
    _info "Evaluate the items above, then run:"
    _info "  ${0} --learn"
    _info "to accept them as known runtime, or bring them into the repo instead."
  fi
else
  _ok "Unknown entries: 0"
fi

echo ""
_ok "Update tools complete."

exit 0
