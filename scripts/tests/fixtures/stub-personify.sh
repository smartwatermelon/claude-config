# shellcheck shell=bash

# Sourced, not a suite: run-tests.sh runs scripts/tests/test-*.sh only.

# _stub_personify <config dir> <install dir>: a length_check.py that passes all.
_stub_personify() {
  mkdir -p "$1/plugins" "$2/scripts"
  printf 'import sys\nsys.exit(0)\n' >"$2/scripts/length_check.py"
  jq -n --arg p "$2" '{plugins:{"personify@personify":[{installPath:$p}]}}' >"$1/plugins/installed_plugins.json"
}
