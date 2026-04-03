#!/usr/bin/env bash
set -euo pipefail

# ~/Developer/claude-config/scripts/update-tools.sh
# Called by _claude_update() in bash profile.
# Maintains symlink health, updates submodules, and audits ~/.claude/.
# Exit 0 always — must not break the update flow.

trap 'exit 0' ERR

# ── Constants ───────────────────────────────────────────
REPO_DIR="${HOME}/Developer/claude-config"
DEPLOY_DIR="${HOME}/.claude"

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
  git -C "${REPO_DIR}" submodule update --remote --merge
  _ok "Submodules updated"
else
  _ok "No submodules to update"
fi

# ============================================================================
# 3. AUDIT — categorize depth-1 entries in ~/.claude/
# ============================================================================

_info "Auditing ${DEPLOY_DIR}/..."

# Files and directories that Claude Code manages at runtime
_KNOWN_RUNTIME=(
  # Directories
  "agents-local" "backups" "cache" "channels" "debug"
  "file-history" "logs" "memory" "merge-locks" "paste-cache"
  "pending-issues" "plans" "projects" "sessions" "shell-snapshots"
  "tasks" "telemetry" "todos"
  # Files
  ".claude.json" "mcp.json" "mcp-needs-auth-cache.json"
  "stats-cache.json" "blocked-commands.log" "last-review-result.log"
  "settings.local.json" ".credentials.json"
)

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

  if [[ -L "${entry}" ]]; then
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
  _info "Consider adding unknown items to the _KNOWN_RUNTIME list"
  _info "in scripts/update-tools.sh, or bring them into the repo."
else
  _ok "Unknown entries: 0"
fi

echo ""
_ok "Update tools complete."

exit 0
