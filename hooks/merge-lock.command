#!/opt/homebrew/bin/bash
# Finder double-click launcher: opens merge-lock's TUI in a new Terminal
# window. install.sh links it into ~/Applications. Finder starts it with a
# bare environment, hence the full bash path and the sourced profile.
# shellcheck source=/dev/null
source "${HOME}/.profile"
"${HOME}/.local/bin/merge-lock" tui
