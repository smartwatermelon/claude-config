#!/usr/bin/env bash
# gate-lint.sh -- deterministic prose checks for text the gate sees.

# Usage: gate-lint.sh [--mode block|warn] [--allow RULE --reason TEXT]... <kind> <file>

# kind: commit pr issue pr-comment line-comment code-comment docstring copy.

# Check 1: personify length_check.py --kind <kind>. Skipped for copy, which has no cap.

# Check 2: vale with prose/.vale.ini, always by explicit --config.

# Why explicit: bare vale walks up for a .vale.ini and, past the repo root, runs its defaults.

# --mode block (default, gated routes): an error not allowed fails, and so does a length overrun.

# Block mode fails closed when vale is missing. It is in the dotfiles Brewfile.

# --mode warn (exempt routes): print findings and exit 0, even when vale is missing.

# --allow RULE --reason TEXT: accept one vale rule's errors. RULE is Dashes or Andrew.Dashes.

# Each --allow needs its own --reason, right after it. A length cap cannot be allowed.

# Stdout: "gate-lint: <severity|allowed> <Check> line <N>: <message>", one per finding.

# Stdout also: length_check.py's lines, and "gate-lint: allow <Check>: <reason>" per --allow.

# Stderr: tool errors and warn-mode notes, prefixed gate-lint:.

# Exit: 0 pass (warn: always), 1 findings, 2 tool error (vale, personify), 64 usage.

# GATE_LINT_VALE: the vale binary to run, for tests. Default: vale on PATH.

set -euo pipefail
unset CDPATH

USAGE=64
KINDS="commit pr issue pr-comment line-comment code-comment docstring copy"

_usage() {
  printf 'gate-lint: %s\n' "$1" >&2
  echo 'usage: gate-lint.sh [--mode block|warn] [--allow RULE --reason TEXT]... <kind> <file>' >&2
  exit "${USAGE}"
}

# The deployed copy is a symlink under ~/.claude/scripts. The style sits beside the real file.
_self="${BASH_SOURCE[0]}"
if [[ -L "${_self}" ]]; then
  _target="$(readlink "${_self}")"
  [[ "${_target}" == /* ]] || _target="$(dirname "${_self}")/${_target}"
  _self="${_target}"
fi
SCRIPT_DIR="$(cd "$(dirname "${_self}")" && pwd)"
unset _self _target
VALE_CONFIG="$(cd "${SCRIPT_DIR}/.." && pwd)/prose/.vale.ini"
STYLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)/prose/styles/Andrew"
GATE="${SCRIPT_DIR}/gate-review.sh"

mode="block"
kind=""
file=""
allow_rules=()
allow_reasons=()
pending_allow=""
while (($# > 0)); do
  case "$1" in
    --mode)
      (($# >= 2)) || _usage "--mode needs a value"
      mode="$2"
      shift 2
      ;;
    --allow)
      (($# >= 2)) || _usage "--allow needs a rule name"
      [[ -z "${pending_allow}" ]] || _usage "--allow ${pending_allow} has no --reason"
      pending_allow="$2"
      shift 2
      ;;
    --reason)
      (($# >= 2)) || _usage "--reason needs text"
      [[ -n "${pending_allow}" ]] || _usage "--reason must follow an --allow"
      [[ -n "${2//[[:space:]]/}" ]] || _usage "--allow ${pending_allow} needs a non-empty --reason"
      allow_rules+=("${pending_allow}")
      allow_reasons+=("$2")
      pending_allow=""
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*) _usage "unknown option: $1" ;;
    *)
      if [[ -z "${kind}" ]]; then
        kind="$1"
      elif [[ -z "${file}" ]]; then
        file="$1"
      else
        _usage "unexpected argument: $1"
      fi
      shift
      ;;
  esac
done
while (($# > 0)); do
  if [[ -z "${kind}" ]]; then
    kind="$1"
  elif [[ -z "${file}" ]]; then
    file="$1"
  else
    _usage "unexpected argument: $1"
  fi
  shift
done

[[ -z "${pending_allow}" ]] || _usage "--allow ${pending_allow} has no --reason"
case "${mode}" in
  block | warn) ;;
  *) _usage "--mode must be block or warn, not '${mode}'" ;;
esac
[[ -n "${kind}" && -n "${file}" ]] || _usage "a kind and a file are required"
known=0
for k in ${KINDS}; do
  [[ "${k}" == "${kind}" ]] && known=1
done
((known == 1)) || _usage "unknown kind '${kind}'; one of: ${KINDS}"
[[ -f "${file}" ]] || _usage "no such file: ${file}"

# An unknown rule is refused: a typo would allow nothing and look like it worked.
for i in "${!allow_rules[@]}"; do
  r="${allow_rules[${i}]#Andrew.}"
  [[ "${r}" =~ ^[A-Za-z]+$ && -f "${STYLE_DIR}/${r}.yml" ]] ||
    _usage "--allow ${allow_rules[${i}]}: no such rule in ${STYLE_DIR}"
  allow_rules[i]="Andrew.${r}"
done

# A check that cannot run: exit 2 in block mode, a warning in warn mode.
TOOL_FAILED=0
_tool_error() {
  if [[ "${mode}" == "block" ]]; then
    printf 'gate-lint: %s\n' "$1" >&2
    TOOL_FAILED=1
  else
    printf 'gate-lint: warning: %s; this check was skipped\n' "$1" >&2
  fi
}

TMPDIR_LINT="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_LINT}"' EXIT

failed=0

# --- 1. length caps -------------------------------------------------------
if [[ "${kind}" != "copy" ]]; then
  if [[ ! -x "${GATE}" ]]; then
    _tool_error "no gate-review.sh at ${GATE}, so personify cannot be found"
  elif ! pdir="$("${GATE}" personify-path 2>"${TMPDIR_LINT}/perr")"; then
    msg="$(tail -1 "${TMPDIR_LINT}/perr" || true)"
    _tool_error "${msg}"
  elif [[ ! -f "${pdir}/scripts/length_check.py" ]]; then
    _tool_error "no ${pdir}/scripts/length_check.py; update personify"
  else
    rc=0
    python3 "${pdir}/scripts/length_check.py" --kind "${kind}" <"${file}" \
      >"${TMPDIR_LINT}/len" 2>"${TMPDIR_LINT}/lenerr" || rc=$?
    case "${rc}" in
      0) ;;
      1)
        while IFS= read -r line; do
          if [[ -n "${line}" ]]; then
            printf 'gate-lint: %s\n' "${line}"
          fi
        done <"${TMPDIR_LINT}/len"
        failed=1
        ;;
      *)
        msg="$(grep -v '^usage:' "${TMPDIR_LINT}/lenerr" | tail -1 || true)"
        _tool_error "length checker error: ${msg:-length_check.py exited ${rc} with no message}"
        ;;
    esac
  fi
fi

# --- 2. vale --------------------------------------------------------------
VALE_BIN="${GATE_LINT_VALE:-vale}"
if ! vale_path="$(command -v "${VALE_BIN}")"; then
  _tool_error "vale is not installed (${VALE_BIN} not found); install it with: brew install vale"
elif [[ ! -f "${VALE_CONFIG}" ]]; then
  _tool_error "no vale config at ${VALE_CONFIG}"
else
  rc=0
  # Stdin, so an extensionless file name never picks the format.

  # --no-exit, so a nonzero exit always means vale itself failed.
  "${vale_path}" --config "${VALE_CONFIG}" --output=JSON --ext=.md --no-exit \
    <"${file}" >"${TMPDIR_LINT}/vale.json" 2>"${TMPDIR_LINT}/vale.err" || rc=$?
  if ((rc != 0)); then
    msg="$(cat "${TMPDIR_LINT}/vale.err" "${TMPDIR_LINT}/vale.json" | tr '\n' ' ')"
    _tool_error "vale exited ${rc}: ${msg}"
  else
    : >"${TMPDIR_LINT}/allow"
    for r in "${allow_rules[@]+"${allow_rules[@]}"}"; do
      printf '%s\n' "${r}" >>"${TMPDIR_LINT}/allow"
    done
    rc=0
    # Python, not jq: a jq expression that raises drops the record and still exits 0.

    # The parser exits 0 clean, 1 blocking errors, 3 unreadable output, never 1 on a crash.
    python3 -I - "${TMPDIR_LINT}/vale.json" "${TMPDIR_LINT}/allow" \
      >"${TMPDIR_LINT}/findings" 2>"${TMPDIR_LINT}/pyerr" <<'PY' || rc=$?
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    with open(sys.argv[2], encoding="utf-8") as fh:
        allowed = {line.strip() for line in fh if line.strip()}
    if not isinstance(data, dict):
        raise ValueError(f"unexpected vale output: {str(data)[:200]}")
    lines = []
    blocking = 0
    for alerts in data.values():
        if not isinstance(alerts, list):
            raise ValueError(f"unexpected vale output: {str(alerts)[:200]}")
        for a in alerts:
            check = a["Check"]
            sev = a["Severity"]
            text = f"{check} line {a['Line']}: {a['Message']}"
            if sev == "error" and check in allowed:
                lines.append(f"gate-lint: allowed {text}")
            else:
                lines.append(f"gate-lint: {sev} {text}")
                if sev == "error":
                    blocking += 1
except Exception as exc:  # noqa: BLE001
    print(f"{type(exc).__name__}: {exc}", file=sys.stderr)
    sys.exit(3)
for line in lines:
    print(line)
sys.exit(1 if blocking else 0)
PY
    cat "${TMPDIR_LINT}/findings"
    case "${rc}" in
      0) ;;
      1) failed=1 ;;
      *)
        msg="$(tail -1 "${TMPDIR_LINT}/pyerr" || true)"
        _tool_error "cannot read vale's output: ${msg}"
        ;;
    esac
  fi
fi

for i in "${!allow_rules[@]}"; do
  printf 'gate-lint: allow %s: %s\n' "${allow_rules[${i}]}" "${allow_reasons[${i}]}"
done

[[ "${mode}" == "warn" ]] && exit 0
((TOOL_FAILED == 0)) || exit 2
exit "${failed}"
