#!/usr/bin/env bash
# update-tools.sh with the deploy clone (#453): which copy it repairs, where --learn writes.
# HOME is a mktemp -d; install.sh is a stub.

set -euo pipefail
unset CDPATH

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update-tools.sh"
ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "${ROOT_TMP}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

pass=0
fail=0
check() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS: ${desc}"
    ((pass += 1))
  else
    echo "  FAIL: ${desc}"
    ((fail += 1))
  fi
}

make_repo() {
  local dir="$1"
  mkdir -p "${dir}/scripts" "${dir}/hooks"
  git init -q "${dir}"
  cat >"${dir}/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(cd "$(dirname "$0")" && pwd)" "$*" >>"${STUB_INSTALL_LOG}"
EOF
  chmod +x "${dir}/install.sh"
  printf '# Directories\nprojects\n\n# Files\n.claude.json\n' >"${dir}/scripts/known-runtime.txt"
  printf '#!/usr/bin/env bash\n' >"${dir}/hooks/run-review.sh"
  git -C "${dir}" add -A
  git -c user.name=T -c user.email=t@t -c commit.gpgSign=false -C "${dir}" commit -q -m init
}

fresh() {
  T="$(mktemp -d "${ROOT_TMP}/case.XXXXXX")"
  export HOME="${T}/home"
  CLONE="${HOME}/.local/share/claude-config"
  DEV="${HOME}/Developer/claude-config"
  export STUB_INSTALL_LOG="${T}/install.log"
  touch "${STUB_INSTALL_LOG}"
  mkdir -p "${HOME}/.claude/hooks"
  make_repo "${DEV}"
}

run_update() {
  rc=0
  out="$("${BASH}" "${SCRIPT}" "$@" 2>&1)" || rc=$?
}

echo "=== update-tools.sh and the deploy clone ==="

fresh
run_update
check "no clone: exits 0" test "${rc}" -eq 0
check "no clone: repairs from the working checkout" grep -qx "${DEV} --repair" "${STUB_INSTALL_LOG}"

fresh
make_repo "${CLONE}"
ln -s "${CLONE}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
run_update
check "deployed: repairs from the clone" grep -qx "${CLONE} --repair" "${STUB_INSTALL_LOG}"
check "deployed: not from the working checkout" test "$(grep -c "^${DEV} " "${STUB_INSTALL_LOG}" || true)" -eq 0

fresh
make_repo "${CLONE}"
ln -s "${DEV}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
run_update
check "dev mode: no repair from either copy" test ! -s "${STUB_INSTALL_LOG}"
check "dev mode: says so" grep -q "dev mode" <<<"${out}"

fresh
make_repo "${CLONE}"
ln -s "${CLONE}/hooks/run-review.sh" "${HOME}/.claude/hooks/run-review.sh"
mkdir -p "${HOME}/.claude/newthing"
run_update --learn
check "--learn: writes the working checkout's known-runtime.txt" grep -qx newthing "${DEV}/scripts/known-runtime.txt"
clone_status="$(git -C "${CLONE}" status --porcelain)"
check "--learn: leaves the clone's copy alone" test -z "${clone_status}"
check "--learn: the review hint names the working checkout" grep -q "git -C ${DEV} diff" <<<"${out}"

echo ""
echo "Results: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
