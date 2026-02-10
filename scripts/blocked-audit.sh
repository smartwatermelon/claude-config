#!/usr/bin/env bash
# View blocked command attempts

set -euo pipefail

LOG_FILE="${HOME}/.claude/blocked-commands.log"

if [[ ! -f "${LOG_FILE}" ]]; then
  echo "No blocked commands logged yet."
  exit 0
fi

case "${1:-show}" in
  show)
    echo "=== Blocked Command Attempts ==="
    cat "${LOG_FILE}"
    ;;
  count)
    echo "Total blocked attempts: $(wc -l <"${LOG_FILE}" | tr -d ' ')"
    ;;
  today)
    today=$(date -u +%Y-%m-%d)
    echo "=== Blocked Today (${today}) ==="
    grep "^${today}" "${LOG_FILE}" || echo "None"
    ;;
  clear)
    echo "Clearing log..."
    rm -f "${LOG_FILE}"
    echo "Log cleared."
    ;;
  *)
    echo "Usage: $0 {show|count|today|clear}"
    ;;
esac
