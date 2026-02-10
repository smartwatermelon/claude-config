#!/usr/bin/env bash
# ~/.claude/hooks/merge-lock.sh
# Merge authorization lock - requires human to authorize before agent can merge
set -euo pipefail

LOCK_DIR="${HOME}/.claude/merge-locks"
LOCK_TTL_SECONDS=1800 # 30 minutes

mkdir -p "${LOCK_DIR}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

create_merge_lock() {
  local pr_number="$1"
  local reason="${2:-Manual authorization}"
  local lock_file="${LOCK_DIR}/pr-${pr_number}.lock"

  local user
  user=$(whoami)
  local ts
  ts=$(date +%s)

  {
    echo "PR_NUMBER=${pr_number}"
    echo "AUTHORIZED_BY=${user}"
    echo "TIMESTAMP=${ts}"
    echo "REASON=${reason}"
  } >"${lock_file}"

  echo -e "${GREEN}[merge-lock]${NC} Authorization created for PR #${pr_number}"
  echo -e "${GREEN}[merge-lock]${NC} Valid for 30 minutes"
  echo -e "${GREEN}[merge-lock]${NC} Lock file: ${lock_file}"
}

check_merge_lock() {
  local pr_number="$1"
  local lock_file="${LOCK_DIR}/pr-${pr_number}.lock"

  [[ ! -f "${lock_file}" ]] && return 1

  local timestamp
  timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2)
  local now
  now=$(date +%s)
  local age=$((now - timestamp))

  if [[ ${age} -gt ${LOCK_TTL_SECONDS} ]]; then
    rm -f "${lock_file}"
    return 1
  fi
  return 0
}

show_status() {
  local pr_number="$1"
  local lock_file="${LOCK_DIR}/pr-${pr_number}.lock"

  if [[ -f "${lock_file}" ]]; then
    local timestamp
    timestamp=$(grep "^TIMESTAMP=" "${lock_file}" | cut -d= -f2)
    local now
    now=$(date +%s)
    local age=$((now - timestamp))
    local remaining=$((LOCK_TTL_SECONDS - age))

    if [[ ${remaining} -gt 0 ]]; then
      local auth_by
      auth_by=$(grep "^AUTHORIZED_BY=" "${lock_file}" | cut -d= -f2 || true)
      local auth_reason
      auth_reason=$(grep "^REASON=" "${lock_file}" | cut -d= -f2 || true)
      echo -e "${GREEN}[merge-lock]${NC} PR #${pr_number} is authorized"
      echo "  Authorized by: ${auth_by}"
      echo "  Reason: ${auth_reason}"
      echo "  Expires in: $((remaining / 60)) minutes"
    else
      echo -e "${YELLOW}[merge-lock]${NC} PR #${pr_number} authorization expired"
      rm -f "${lock_file}"
    fi
  else
    echo -e "${RED}[merge-lock]${NC} PR #${pr_number} is NOT authorized"
    echo ""
    echo "To authorize merge (valid 30 minutes):"
    echo "  ~/.claude/hooks/merge-lock.sh authorize ${pr_number} \"reason\""
  fi
}

list_locks() {
  echo "=== Active Merge Authorizations ==="
  local found=false
  for lock_file in "${LOCK_DIR}"/*.lock; do
    [[ ! -f "${lock_file}" ]] && continue
    found=true
    local pr
    pr=$(grep "^PR_NUMBER=" "${lock_file}" | cut -d= -f2)
    local auth
    auth=$(grep "^AUTHORIZED_BY=" "${lock_file}" | cut -d= -f2)
    local reason
    reason=$(grep "^REASON=" "${lock_file}" | cut -d= -f2)
    echo "  PR #${pr} - by ${auth} - ${reason}"
  done
  if [[ "${found}" == false ]]; then
    echo "  (none)"
  fi
}

case "${1:-help}" in
  authorize | auth)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 authorize <pr_number> [reason]"
      exit 1
    fi
    create_merge_lock "$2" "${3:-}"
    ;;
  check)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 check <pr_number>"
      exit 1
    fi
    if check_merge_lock "$2"; then
      echo "Authorized"
      exit 0
    else
      echo "Not authorized"
      exit 1
    fi
    ;;
  status)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: $0 status <pr_number>"
      exit 1
    fi
    show_status "$2"
    ;;
  list)
    list_locks
    ;;
  *)
    echo "Usage: $0 {authorize|check|status|list} [pr_number] [reason]"
    echo ""
    echo "Commands:"
    echo "  authorize <pr> [reason]  - Create merge authorization (30 min TTL)"
    echo "  check <pr>               - Check if PR is authorized (exit 0/1)"
    echo "  status <pr>              - Show detailed authorization status"
    echo "  list                     - List all active authorizations"
    ;;
esac
