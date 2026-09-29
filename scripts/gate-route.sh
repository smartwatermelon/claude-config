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
# naming the file (and 1-based line number) on any error. On error the arrays
# are left empty, so a caller never routes on a truncated rule set.
_load_rules() {
  _load_rules_inner "$@" || {
    RULE_KIND=()
    RULE_VALUE=()
    RULE_OUTCOME=()
    return 4
  }
}

_load_rules_inner() {
  local file="$1" line lineno=0 matcher outcome extra kind value
  RULE_KIND=()
  RULE_VALUE=()
  RULE_OUTCOME=()
  if [[ ! -r "${file}" || ! -f "${file}" ]]; then
    echo "gate-route: rules file not found or unreadable: ${file} (to deploy it, run install.sh --sync in the claude-config repo)" >&2
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
  local repo="${1:-}" author="${2:-}" i
  repo="${repo,,}"
  author="${author,,}"
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

# _repo_from_dir <dir>
# Print lowercase owner/name from <dir>'s origin URL, or nothing.
_repo_from_dir() {
  local dir="$1" url
  url="$(git -C "${dir}" config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "${url}" ]] || return 0
  url="$(printf '%s\n' "${url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#\.git/?$##; s#/$##')"
  printf '%s\n' "${url,,}"
}

# _author_for_repo <owner/name> <dir>
# Print the gh identity for the repo's owner, or nothing. Sources the gh
# wrapper in a subshell so its state never leaks into this process.
_author_for_repo() {
  local repo="$1" dir="$2" lib="${GH_WRAPPER_LIB:-${HOME}/.config/bash/gh-wrapper.sh}"
  [[ -n "${repo}" && -r "${lib}" ]] || return 0
  (
    # shellcheck source=/dev/null
    source "${lib}" >/dev/null 2>&1 || exit 0
    [[ -d "${dir}" ]] && cd "${dir}"
    _gh_wrapper_identity_for_owner "${repo%%/*}" 2>/dev/null
  ) || true
}

main() {
  set -euo pipefail
  local repo="" dir="." author rules_file result
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        [[ $# -ge 2 ]] || { echo "gate-route: --repo needs a value" >&2; exit 2; }
        repo="${2,,}"
        shift 2
        ;;
      --dir)
        [[ $# -ge 2 ]] || { echo "gate-route: --dir needs a value" >&2; exit 2; }
        dir="$2"
        shift 2
        ;;
      *)
        echo "usage: gate-route.sh [--repo owner/name] [--dir path]" >&2
        exit 2
        ;;
    esac
  done
  rules_file="${GATE_RULES_FILE:-${HOME}/.claude/gate-rules.conf}"
  _load_rules "${rules_file}" || exit 4
  [[ -n "${repo}" ]] || repo="$(_repo_from_dir "${dir}")"
  [[ -n "${repo}" ]] || echo "gate-route: repo unresolved" >&2
  author="$(_author_for_repo "${repo}" "${dir}")"
  [[ -n "${author}" ]] || echo "gate-route: author unresolved" >&2
  result="$(_match_rule "${repo}" "${author}")" || exit 4
  printf '%s\n' "${result}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
