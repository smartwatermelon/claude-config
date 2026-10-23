#!/usr/bin/env bats
# Guard: no hard-coded /tmp in shipped code.
#
# The Claude Code sandbox denies writes to /tmp (claude-config#779), so a
# script the agent runs through Bash must use TMPDIR. "${TMPDIR:-/tmp}" is
# allowed: the fallback only applies where TMPDIR is unset.
#
# NO_TMP_ROOT overrides the tree under test, so the guard can be checked
# against a known-bad copy. Tests under */tests/ and comment lines are
# skipped.
#
# Two -e patterns, not one: BSD grep mishandles "$" inside a (...|$)
# group and misses lines GNU grep matches, and macOS runs this locally.
#
# Run: bats ~/Developer/claude-config/tests/test_no_hardcoded_tmp.bats

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${NO_TMP_ROOT:-${BATS_TEST_DIRNAME}/..}"
}

# Prints file:line:text for every non-comment /tmp use under the dirs given.
_scan() {
  local root="$1"
  shift
  (
    cd "${root}" || exit 2
    grep -rnE \
      -e '(^|[^A-Za-z0-9_:-])/tmp[/"'"'"' ]' \
      -e '(^|[^A-Za-z0-9_:-])/tmp$' \
      --include='*.sh' --include='*.bash' --include='*.py' \
      "$@" 2>/dev/null |
      grep -v '/tests/' |
      grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
  )
}

@test "no shipped script hard-codes /tmp" {
  run _scan "${ROOT}" scripts hooks skills plugins
  if [ -n "${output}" ]; then
    echo "Hard-coded /tmp (use \"\${TMPDIR:-/tmp}\"; the sandbox denies /tmp):" >&2
    echo "${output}" >&2
    return 1
  fi
}

@test "the guard catches known-bad lines and passes known-good ones" {
  local bad="${BATS_TEST_TMPDIR}/bad/scripts" good="${BATS_TEST_TMPDIR}/good/scripts"
  mkdir -p "${bad}" "${good}" "${BATS_TEST_TMPDIR}/bad/scripts/tests"
  cat >"${bad}/a.sh" <<'EOF'
GQL_STDERR=$(mktemp /tmp/post-push-gql-err.XXXXXX)
open("/tmp/foo")
cp a /tmp
echo hi >/tmp/log
f='/tmp/x'
EOF
  cat >"${good}/a.sh" <<'EOF'
x=$(mktemp "${TMPDIR:-/tmp}/a.XXXX")
p=/private/tmp/claude
dir=/var/tmpfoo
z=/tmp_dir
# a comment about /tmp/ is fine
EOF
  # A test file may use /tmp; the guard skips */tests/.
  echo 'x=/tmp/fixture' >"${bad}/tests/t.sh"

  run _scan "${BATS_TEST_TMPDIR}/bad" scripts
  [ "${#lines[@]}" -eq 5 ]
  [[ "${output}" != *"tests/t.sh"* ]]

  run _scan "${BATS_TEST_TMPDIR}/good" scripts
  [ -z "${output}" ]
}
