#!/usr/bin/env bash
# A stand-in for vale in tests: CI runs on Linux with no vale installed.

# Exit 2 without an absolute --config that exists, so gate-lint must always pass one.

# JSON shape as measured from vale 3.24.0 on 2026-10-22: alerts keyed by "stdin.md".

# Mimics: dashes and "pivotal moment" and 25+ word sentences (errors), "do not" (warning).

set -euo pipefail

config=""
while (($# > 0)); do
  case "$1" in
    --config)
      config="${2:-}"
      shift 2
      ;;
    --config=*)
      config="${1#--config=}"
      shift
      ;;
    *) shift ;;
  esac
done
if [[ "${config}" != /* || ! -f "${config}" ]]; then
  echo "vale-stub: no absolute --config that exists (got '${config}')" >&2
  exit 2
fi

python3 -I -c '
import json
import re
import sys

text = sys.stdin.read()
alerts = []

def add(check, sev, line, msg, match):
    alerts.append({"Check": check, "Severity": sev, "Line": line,
                   "Message": msg, "Match": match, "Span": [1, 1]})

for n, line in enumerate(text.splitlines(), 1):
    for m in re.finditer("[—–]", line):
        add("Andrew.Dashes", "error", n, "Replace the dash.", m.group(0))
    for m in re.finditer("(?i)pivotal moment", line):
        add("Andrew.Phrases", "error", n, "Cut or replace it.", m.group(0))
    for m in re.finditer("(?i)do not", line):
        add("Andrew.Contractions", "warning", n, "Consider a contraction.", m.group(0))
    for sentence in re.split(r"[.!?]", line):
        if len(re.findall(r"\b\w+\b", sentence)) > 25:
            add("Andrew.SentenceLength", "error", n, "More than 25 words.", sentence[:10])
print(json.dumps({"stdin.md": alerts} if alerts else {}))
'
