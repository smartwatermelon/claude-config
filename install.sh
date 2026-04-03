#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/claude-config/install.sh
# Idempotent symlink installer for Claude Code configuration.
# Creates per-file symlinks from this repo into ~/.claude/.
# Safe to re-run at any time — checks before acting.

# ── Formatting helpers ───────────────────────────────────
_info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
_ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
_warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_err()  { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; }
_skip() {
  printf '\033[0;90m[SKIP]\033[0m  %s\n' "$*"
  skipped+=("$*")
}
_dry() { printf '\033[1;35m[DRY]\033[0m   %s\n' "$*"; }

# ── Tracking arrays ─────────────────────────────────────
installed=()
skipped=()
failures=()

# ── Constants ────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${HOME}/.claude"
BACKUP_DIR="${DEPLOY_DIR}/backups/symlink-migration"

# ── Parse arguments ─────────────────────────────────────
DRY_RUN=false
REPAIR_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=true ;;
    --repair)  REPAIR_ONLY=true ;;
    --help)
      echo "Usage: install.sh [--dry-run] [--repair] [--help]"
      echo ""
      echo "  --dry-run  Show what would be done without making changes"
      echo "  --repair   Repair broken symlinks only (no new installs)"
      echo "  --help     Show this help message"
      exit 0
      ;;
    *)
      _err "Unknown argument: ${arg}"
      echo "Usage: install.sh [--dry-run] [--repair] [--help]"
      exit 1
      ;;
  esac
done

if [[ "${DRY_RUN}" == true ]]; then
  _info "Dry-run mode — no changes will be made"
fi

# ============================================================================
# 1. PRE-FLIGHT CHECKS
# ============================================================================

detected_os="$(uname -s)" || true
if [[ "${detected_os}" != "Darwin" ]]; then
  _err "This script is designed for macOS (Darwin). Detected: ${detected_os}"
  exit 1
fi

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  _err "Not a git repository: ${REPO_DIR}"
  _err "This script must be run from the claude-config repo root."
  exit 1
fi

if [[ ! -f "${REPO_DIR}/settings.json" ]]; then
  _err "Canary file missing: ${REPO_DIR}/settings.json"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/CLAUDE.md" ]]; then
  _err "Canary file missing: ${REPO_DIR}/CLAUDE.md"
  exit 1
fi

if [[ ! -f "${REPO_DIR}/hooks/run-review.sh" ]]; then
  _err "Canary file missing: ${REPO_DIR}/hooks/run-review.sh"
  exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
  _err "Do not run this script as root."
  exit 1
fi

_ok "Pre-flight checks passed (macOS, git repo at ${REPO_DIR}, non-root)"

# ============================================================================
# 2. SUBMODULE ROOTS
# ============================================================================

_SUBMODULE_ROOTS=()
while IFS= read -r sm; do
  [[ -n "${sm}" ]] && _SUBMODULE_ROOTS+=("${sm}")
done < <(git -C "${REPO_DIR}" submodule --quiet foreach "echo \$sm_path" 2>/dev/null || true)

if [[ ${#_SUBMODULE_ROOTS[@]} -gt 0 ]]; then
  _info "Found ${#_SUBMODULE_ROOTS[@]} submodule(s): ${_SUBMODULE_ROOTS[*]}"
fi

# Cache tracked file list (avoids repeated git ls-files + fixes SC2312)
_TRACKED_FILES=()
while IFS= read -r _tf; do
  _TRACKED_FILES+=("${_tf}")
done < <(git -C "${REPO_DIR}" ls-files || true)

# ============================================================================
# 3. HELPER FUNCTIONS
# ============================================================================

_is_excluded() {
  case "$1" in
    # CI / GitHub metadata
    .github/*) return 0 ;;
    # Git files
    .gitignore) return 0 ;;
    .gitmodules) return 0 ;;
    .gitattributes) return 0 ;;
    # Repo management
    .editorconfig) return 0 ;;
    .flake8) return 0 ;;
    .pre-commit-config.yaml) return 0 ;;
    # Documentation
    README.md) return 0 ;;
    */README.md) return 0 ;;
    # This script
    install.sh) return 0 ;;
    # Plans
    docs/plans/*) return 0 ;;
    # Licensing
    LICENSE*) return 0 ;;
    # Test files
    *.bats) return 0 ;;
    test-*.sh) return 0 ;;
    tests/*) return 0 ;;
    scripts/tests/*) return 0 ;;
    hooks/tests/*) return 0 ;;
    *) return 1 ;;
  esac
}

_is_submodule_path() {
  local file="$1"
  for sm_path in "${_SUBMODULE_ROOTS[@]}"; do
    case "${file}" in
      "${sm_path}"/*) return 0 ;;
      *) ;;
    esac
  done
  return 1
}

_ensure_symlink() {
  local target="$1" link="$2"

  if [[ -L "${link}" ]]; then
    local current
    current="$(readlink "${link}")"
    if [[ "${current}" == "${target}" ]]; then
      _skip "Symlink already correct: ${link}"
      return
    fi
    _warn "Symlink ${link} points to ${current}, replacing"
    if [[ "${DRY_RUN}" == true ]]; then
      _dry "Would replace symlink: ${link} -> ${target}"
      return
    fi
    rm "${link}"
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    if [[ -e "${link}" ]]; then
      _dry "Would back up and replace: ${link}"
    else
      _dry "Would symlink: ${link} -> ${target}"
    fi
    return
  fi

  # Back up existing regular file
  if [[ -e "${link}" ]]; then
    mkdir -p "${BACKUP_DIR}"
    local backup_name
    backup_name="${link#"${DEPLOY_DIR}/"}"
    backup_name="${backup_name//\//_}.$(date +%Y%m%d%H%M%S)"
    mv "${link}" "${BACKUP_DIR}/${backup_name}"
    _warn "Backed up ${link} to ${BACKUP_DIR}/${backup_name}"
  fi

  mkdir -p "$(dirname "${link}")"
  ln -s "${target}" "${link}"
  _ok "Created symlink: ${link} -> ${target}"
  installed+=("symlink:${link}")
}

# ============================================================================
# 4. REPAIR MODE
# ============================================================================

repair_symlinks() {
  local repair_count=0

  _info "Repair mode — checking for broken symlinks..."

  for file in "${_TRACKED_FILES[@]}"; do
    _is_excluded "${file}" && continue
    _is_submodule_path "${file}" && continue

    local link="${DEPLOY_DIR}/${file}"
    local target="${REPO_DIR}/${file}"

    # Only repair files that exist as regular files where symlinks should be
    if [[ -f "${link}" && ! -L "${link}" ]]; then
      if [[ "${DRY_RUN}" == true ]]; then
        _dry "Would repair: ${link} -> ${target}"
        ((repair_count += 1))
        continue
      fi
      # Compare content — if deploy copy has edits, preserve them and stage
      if ! diff -q "${link}" "${target}" &>/dev/null; then
        _warn "Content differs — copying ${link} back to repo and staging"
        cp "${link}" "${target}"
        git -C "${REPO_DIR}" add "${file}" || _warn "git add failed for ${file} — stage manually"
      fi
      rm "${link}"
      ln -s "${target}" "${link}"
      _ok "Repaired: ${link} -> ${target}"
      ((repair_count += 1))
    fi
  done

  if [[ "${repair_count}" -eq 0 ]]; then
    _ok "All symlinks healthy — nothing to repair"
  else
    _ok "Repaired ${repair_count} symlink(s)"
  fi
}

if ${REPAIR_ONLY}; then
  repair_symlinks
  exit 0
fi

# ============================================================================
# 5. MAIN SYMLINK LOOP
# ============================================================================

_info "Creating config symlinks from repo to ${DEPLOY_DIR}..."

for file in "${_TRACKED_FILES[@]}"; do
  _is_excluded "${file}" && continue
  _is_submodule_path "${file}" && continue

  _ensure_symlink "${REPO_DIR}/${file}" "${DEPLOY_DIR}/${file}"
done

# ============================================================================
# 6. SUBMODULE SYMLINKS (directory-level)
# ============================================================================

if [[ ${#_SUBMODULE_ROOTS[@]} -gt 0 ]]; then
  _info "Creating submodule directory symlinks..."
  for sm_path in "${_SUBMODULE_ROOTS[@]}"; do
    _ensure_symlink "${REPO_DIR}/${sm_path}" "${DEPLOY_DIR}/${sm_path}"
  done
fi

# ============================================================================
# 7. POST-INSTALL SMOKE TESTS
# ============================================================================

_info "Running smoke tests..."

if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would run smoke tests (skipped in dry-run mode)"
else

# Key files must be symlinks
for key_file in settings.json CLAUDE.md; do
  link="${DEPLOY_DIR}/${key_file}"
  if [[ -L "${link}" ]]; then
    if [[ -e "${link}" ]]; then
      _ok "Symlink resolves: ${link}"
    else
      _warn "Broken symlink: ${link}"
      failures+=("broken-symlink:${key_file}")
    fi
  elif [[ -e "${link}" ]]; then
    _warn "Not a symlink (expected symlink): ${link}"
    failures+=("not-symlink:${key_file}")
  else
    _warn "Missing: ${link}"
    failures+=("missing:${key_file}")
  fi
done

# Hook scripts must be symlinks and executable
for file in "${_TRACKED_FILES[@]}"; do
  case "${file}" in
    hooks/*.sh)
      _is_excluded "${file}" && continue
      link="${DEPLOY_DIR}/${file}"
      if [[ -L "${link}" ]]; then
        if [[ ! -e "${link}" ]]; then
          _warn "Broken hook symlink: ${link}"
          failures+=("broken-hook:${file}")
        elif [[ ! -x "${link}" ]]; then
          _warn "Hook not executable: ${link}"
          failures+=("not-executable:${file}")
        else
          _ok "Hook symlink OK: ${file}"
        fi
      elif [[ -e "${link}" ]]; then
        _warn "Hook not a symlink: ${link}"
        failures+=("not-symlink:${file}")
      fi
      ;;
    *) ;;
  esac
done

fi  # end dry-run skip for smoke tests

# Full symlink health check — verify all non-excluded deploy paths
if [[ "${DRY_RUN}" == true ]]; then
  _dry "Would verify symlink health for all tracked files"
else
  _info "Checking symlink health..."
  symlink_errors=0
  for file in "${_TRACKED_FILES[@]}"; do
    _is_excluded "${file}" && continue
    _is_submodule_path "${file}" && continue

    link="${DEPLOY_DIR}/${file}"
    if [[ -L "${link}" ]]; then
      if [[ ! -e "${link}" ]]; then
        _warn "Broken symlink: ${link}"
        failures+=("broken-symlink:${link}")
        ((symlink_errors += 1))
      fi
    elif [[ -e "${link}" ]]; then
      _warn "Not a symlink (expected symlink): ${link}"
      failures+=("not-symlink:${link}")
      ((symlink_errors += 1))
    else
      _warn "Missing symlink: ${link}"
      failures+=("missing-symlink:${link}")
      ((symlink_errors += 1))
    fi
  done

  if [[ "${symlink_errors}" -eq 0 ]]; then
    _ok "All config symlinks healthy"
  fi
fi

# ============================================================================
# 8. SUMMARY
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Claude Config Install Summary"
echo "═══════════════════════════════════════════════════════"

if [[ ${#installed[@]} -gt 0 ]]; then
  _info "Installed/created:"
  for item in "${installed[@]}"; do
    echo "  + ${item}"
  done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
  echo ""
  _info "Skipped (already present):"
  for item in "${skipped[@]}"; do
    echo "  - ${item}"
  done
fi

if [[ ${#failures[@]} -gt 0 ]]; then
  echo ""
  _warn "Issues found:"
  for item in "${failures[@]}"; do
    echo "  ! ${item}"
  done
fi

echo ""

if [[ ${#failures[@]} -gt 0 ]]; then
  _err "Completed with ${#failures[@]} issue(s). Review warnings above."
  exit 1
fi

_ok "All done — ${#installed[@]} installed, ${#skipped[@]} skipped, 0 failures."
