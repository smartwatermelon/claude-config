#!/usr/bin/env bash
# gate-route.sh -- routing rules for the commit/PR text gate.
#
# Rules file: ${GATE_RULES_FILE:-${HOME}/.claude/gate-rules.conf}
# One rule per line: "<matcher> <outcome>". First match wins.
#   matcher: repo=<owner/name> | author=<login> | owner=<login> | fork=<login> | *
#   outcome: pangram | visual | exempt

# fork=<login>: owner=<login> and GitHub says fork. Unknown never matches, so keep only gated rules below it.

# --publish: gh posts from the --dir checkout. For a fork, unknown, or second remote: origin or `*`, the stricter.

# owner=<login> matches the owner part of an owner/name destination, exactly
# and case-insensitively, and only when the destination host is github.com.
# A --repo value (gh's owner/name) counts as github.com; a --dir origin must
# name github.com itself. Any other host, or none, falls through (fail closed).
# author= cannot do this job: the gh wrapper maps every unknown owner to
# twistedmelonman, so it cannot tell a personal repo from someone else's.
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
      owner=?* | fork=?*)
        kind="${matcher%%=*}"
        value="${matcher#*=}"
        if [[ "${value}" == */* ]]; then
          echo "gate-route: ${file}:${lineno}: ${kind} value must not contain '/': '${matcher}'" >&2
          return 4
        fi
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

# _match_rule <repo> <author> [host]
# Print "<outcome>\t<rule number>\t<reason>" for the first matching rule.
# Return 4 if no rule matches. An owner rule needs host github.com and a repo
# of exactly owner/name; without both it never matches.
_match_rule() {
  local repo="${1:-}" author="${2:-}" host="${3:-}" i
  repo="${repo,,}"
  author="${author,,}"
  host="${host,,}"
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
      owner)
        if [[ "${host}" == "github.com" && "${repo}" =~ ^[^/]+/[^/]+$ && "${repo%%/*}" == "${RULE_VALUE[i]}" ]]; then
          printf '%s\t%d\tmatched owner=%s\n' "${RULE_OUTCOME[i]}" "$((i + 1))" "${RULE_VALUE[i]}"
          return 0
        fi
        ;;
      fork)
        # Only a proven fork matches; not-a-fork and unknown both skip the rule.
        if [[ "${host}" == "github.com" && "${repo}" =~ ^[^/]+/[^/]+$ && "${repo%%/*}" == "${RULE_VALUE[i]}" ]] &&
          _is_fork "${repo}"; then
          printf '%s\t%d\tmatched fork=%s\n' "${RULE_OUTCOME[i]}" "$((i + 1))" "${RULE_VALUE[i]}"
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

# _is_fork <owner/name>: 0 fork, 1 not a fork, 2 unknown. Callers treat 2 as not proven (gated).

# Cache: gate-review/fork-cache/, which the write hooks guard. Answers only, 7 days; failures never.
_is_fork() {
  local repo="${1,,}" dir file ans="" now mtime ttl="${GATE_FORK_CACHE_TTL:-604800}"
  [[ "${repo}" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ ]] || return 2
  case "/${repo}/" in
    */./* | */../*) return 2 ;;
    *) ;;
  esac
  dir="${GATE_REVIEW_DIR:-${HOME}/.claude/gate-review}/fork-cache/${repo%%/*}"
  file="${dir}/${repo#*/}"
  if [[ -f "${file}" ]]; then
    now="$(date +%s)"
    # GNU first, as in gate-review.sh: GNU `stat -f %m` fails but still prints filesystem info.
    mtime="$(stat -c %Y "${file}" 2>/dev/null || stat -f %m "${file}" 2>/dev/null || echo 0)"
    [[ "${mtime}" =~ ^[0-9]+$ ]] || mtime=0
    if ((now - mtime < ttl)); then
      ans="$(cat "${file}" 2>/dev/null || true)"
    fi
  fi
  if [[ "${ans}" != "true" && "${ans}" != "false" ]]; then
    ans="$("${GATE_GH:-gh}" api "repos/${repo}" --jq '.fork' 2>/dev/null </dev/null || true)"
    if [[ "${ans}" == "true" || "${ans}" == "false" ]]; then
      mkdir -p "${dir}" 2>/dev/null && printf '%s\n' "${ans}" >"${file}" 2>/dev/null || true
    fi
  fi
  case "${ans}" in
    true) return 0 ;;
    false) return 1 ;;
    *) return 2 ;;
  esac
}

# _other_remote <dir> <owner/name>: 0 if any remote names another repo. gh may publish to that one.
_other_remote() {
  local dir="$1" want="$2" url r
  while IFS= read -r url; do
    [[ -n "${url}" ]] || continue
    r="$(printf '%s\n' "${url}" | sed -E 's#^(git@[^:]+:|[a-zA-Z]+://[^/]+/)##; s#\.git/?$##; s#/$##')"
    [[ "${r,,}" == "${want}" ]] || return 0
  done < <(git -C "${dir}" config --get-regexp '^remote\..*\.url$' 2>/dev/null | awk '{print $2}' || true)
  return 1
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

# _host_from_dir <dir>
# Print the lowercase host of <dir>'s origin URL, or nothing when there is no
# origin or the URL names no host (a local path or file://). Handles
# scheme://[user@]host[:port]/path and scp-like [user@]host:path.
_host_from_dir() {
  local dir="$1" url host
  url="$(git -C "${dir}" config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "${url}" ]] || return 0
  if [[ "${url}" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]]; then
    host="${url#*://}"
    host="${host%%/*}"
    host="${host##*@}"
    host="${host%%:*}"
  elif [[ "${url}" == *:* && "${url%%:*}" != */* ]]; then
    host="${url%%:*}"
    host="${host##*@}"
  else
    return 0
  fi
  [[ -n "${host}" ]] && printf '%s\n' "${host,,}"
  return 0
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
  local repo="" dir="." author host="" rules_file result publish=0 fork_rc=0 uncertain=0 other s_other s_result
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --publish)
        publish=1
        shift
        ;;
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
        echo "usage: gate-route.sh [--repo owner/name] [--dir path] [--publish]" >&2
        exit 2
        ;;
    esac
  done
  rules_file="${GATE_RULES_FILE:-${HOME}/.claude/gate-rules.conf}"
  _load_rules "${rules_file}" || exit 4
  if [[ -n "${repo}" ]]; then
    # gh resolves a bare owner/name (-R, a repos/ path, a github.com URL) on
    # github.com.
    host="github.com"
  else
    repo="$(_repo_from_dir "${dir}")"
    host="$(_host_from_dir "${dir}")"
    if ((publish == 1)) && [[ -n "${repo}" ]]; then
      _is_fork "${repo}" || fork_rc=$?
      if ((fork_rc != 1)); then
        echo "gate-route: ${repo} is a fork, or its fork status is unknown; gh may publish to the parent; name the repository with gh -R <owner/name>" >&2
        uncertain=1
      elif _other_remote "${dir}" "${repo}"; then
        echo "gate-route: ${dir} has a remote other than ${repo}; gh may publish there; name the repository with gh -R <owner/name>" >&2
        uncertain=1
      fi
    fi
  fi
  [[ -n "${repo}" ]] || echo "gate-route: repo unresolved" >&2
  author="$(_author_for_repo "${repo}" "${dir}")"
  [[ -n "${author}" ]] || echo "gate-route: author unresolved" >&2
  result="$(_match_rule "${repo}" "${author}" "${host}")" || exit 4
  # Uncertain: the text must satisfy both the origin and an unknown repo, so the stricter route wins.
  if ((uncertain == 1)); then
    other="$(_match_rule "" "" "${host}")" || exit 4
    s_other="$(_strength "${other%%$'\t'*}")"
    s_result="$(_strength "${result%%$'\t'*}")"
    if ((s_other > s_result)); then
      result="${other}"
    fi
  fi
  printf '%s\n' "${result}"
}

# _strength <outcome>: exempt 0, visual 1, pangram 2. Anything else is treated as the strictest.
_strength() {
  case "$1" in
    exempt) printf '0\n' ;;
    visual) printf '1\n' ;;
    *) printf '2\n' ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
