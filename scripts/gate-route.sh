#!/usr/bin/env bash
# gate-route.sh -- routing rules for the commit/PR text gate.
#
# Rules file: ${GATE_RULES_FILE:-${HOME}/.claude/gate-rules.conf}
# One rule per line: "<matcher> <outcome>". First match wins.
#   matcher: repo=<owner/name> | author=<login> | *
#   outcome: pangram | visual | exempt
#
# Sourced by tests and later tasks: main runs only when executed.

RULE_KIND=()
RULE_VALUE=()
RULE_OUTCOME=()

# _load_rules <file>
# Fill RULE_KIND, RULE_VALUE, RULE_OUTCOME. Return 4 with a stderr message
# naming the file (and 1-based line number) on any error.
_load_rules() {
  local file="$1" line lineno=0 matcher outcome extra kind value
  RULE_KIND=()
  RULE_VALUE=()
  RULE_OUTCOME=()
  if [[ ! -r "${file}" || ! -f "${file}" ]]; then
    echo "gate-route: rules file not found or unreadable: ${file}" >&2
    return 4
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="${line//$'\r'/}"
    # Split on runs of spaces and tabs; a leading '#' field is a comment.
    read -r matcher outcome extra <<<"${line}"
    [[ -z "${matcher}" || "${matcher}" == \#* ]] && continue
    if [[ -z "${outcome}" || -n "${extra}" ]]; then
      echo "gate-route: ${file}:${lineno}: expected '<matcher> <outcome>'" >&2
      return 4
    fi
    case "${matcher}" in
      '*')
        kind="any"
        value=""
        ;;
      repo=?*)
        kind="repo"
        value="${matcher#repo=}"
        ;;
      author=?*)
        kind="author"
        value="${matcher#author=}"
        ;;
      *)
        echo "gate-route: ${file}:${lineno}: unknown matcher '${matcher}'" >&2
        return 4
        ;;
    esac
    case "${outcome}" in
      pangram | visual | exempt) ;;
      *)
        echo "gate-route: ${file}:${lineno}: unknown outcome '${outcome}'" >&2
        return 4
        ;;
    esac
    RULE_KIND+=("${kind}")
    RULE_VALUE+=("${value,,}")
    RULE_OUTCOME+=("${outcome}")
  done <"${file}"
  return 0
}

# _match_rule <repo> <author>
# Print "<outcome>\t<rule number>\t<reason>" for the first matching rule.
# Return 4 if no rule matches.
_match_rule() {
  local repo="${1,,}" author="${2,,}" i
  for i in "${!RULE_KIND[@]}"; do
    case "${RULE_KIND[i]}" in
      repo)
        if [[ "${repo}" == "${RULE_VALUE[i]}" ]]; then
          printf '%s\t%d\tmatched repo=%s\n' "${RULE_OUTCOME[i]}" "$((i + 1))" "${RULE_VALUE[i]}"
          return 0
        fi
        ;;
      author)
        if [[ "${author}" == "${RULE_VALUE[i]}" ]]; then
          printf '%s\t%d\tmatched author=%s\n' "${RULE_OUTCOME[i]}" "$((i + 1))" "${RULE_VALUE[i]}"
          return 0
        fi
        ;;
      any)
        printf '%s\t%d\tno rule matched, default\n' "${RULE_OUTCOME[i]}" "$((i + 1))"
        return 0
        ;;
      *)
        echo "gate-route: internal error: bad rule kind '${RULE_KIND[i]}'" >&2
        return 4
        ;;
    esac
  done
  echo "gate-route: no rule matched" >&2
  return 4
}

main() {
  set -euo pipefail
  echo "usage: gate-route.sh (CLI not implemented yet)" >&2
  exit 2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
