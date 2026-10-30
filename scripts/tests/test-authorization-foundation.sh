#!/usr/bin/env bash
# Targeted offline suite; no live policy, credentials or Claude invocation.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -m unittest discover -s "${repo_root}/security/tests" -v
