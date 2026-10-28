#!/usr/bin/env bats
# rotate_disagreement_log() in hooks/run-review.sh.
#
# .git/reviewer-disagreements.log is append-only and was never rotated. Since
# claude-config#418 nothing reads it programmatically, and since #799 every
# cleared block appends a quoted proof to it as well. Over the size cap it is
# renamed to <log>.1 (one generation) before the next append.
#
# Safety (Protocol 3): the rename runs through REVIEW_MV_BIN. The stub tests
# record its arguments and touch nothing. The real-mv tests use only paths
# under ${BATS_TEST_TMPDIR}. Nothing here deletes.
#
# Run: bats tests/test_run_review_disagreement_rotation.bats

SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"

setup() {
  eval "$(sed -n '/^rotate_disagreement_log() {/,/^}/p' "${SCRIPT}")"
  LOGDIR="${BATS_TEST_TMPDIR}/gitdir"
  mkdir -p "${LOGDIR}"
  LOG="${LOGDIR}/reviewer-disagreements.log"
  # Read by the eval-loaded function, which shellcheck cannot see.
  export DISAGREEMENT_LOG="${LOG}" DISAGREEMENT_LOG_MAX_BYTES=100
  MV_RECORD="${BATS_TEST_TMPDIR}/mv-calls"
  # Stub: records its arguments, one call per line, and renames nothing.
  STUB_MV="${BATS_TEST_TMPDIR}/stub-mv"
  cat >"${STUB_MV}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${MV_RECORD}"
exit "\${STUB_MV_EXIT:-0}"
EOF
  chmod +x "${STUB_MV}"
  export REVIEW_MV_BIN="${STUB_MV}"
}

_fill() { # _fill <bytes>
  head -c "$1" /dev/zero | tr '\0' 'x' >"${LOG}"
}

@test "a log over the cap is renamed to <log>.1" {
  _fill 101
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ "$(cat "${MV_RECORD}")" = "-f ${LOG} ${LOG}.1" ]
}

@test "a log at or under the cap is left alone" {
  _fill 100
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ ! -e "${MV_RECORD}" ]
}

@test "a missing log is not created and nothing is renamed" {
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ ! -e "${MV_RECORD}" ]
  [ ! -e "${LOG}" ]
}

@test "an empty DISAGREEMENT_LOG setting is a no-op" {
  DISAGREEMENT_LOG="" run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ ! -e "${MV_RECORD}" ]
}

@test "a symlinked log is not renamed" {
  printf '%0200d\n' 0 >"${LOGDIR}/target.log"
  ln -s "${LOGDIR}/target.log" "${LOG}"
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ ! -e "${MV_RECORD}" ]
}

@test "a failed rename never fails the caller" {
  _fill 101
  STUB_MV_EXIT=1
  export STUB_MV_EXIT
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ -s "${MV_RECORD}" ]
}

@test "real mv in the test temp dir: one generation, the older .1 is replaced" {
  REVIEW_MV_BIN="mv"
  printf 'OLDEST\n' >"${LOG}.1"
  _fill 101
  printf 'NEWER\n' >>"${LOG}"
  run rotate_disagreement_log
  [ "$status" -eq 0 ]
  [ ! -e "${LOG}" ]
  grep -q 'NEWER' "${LOG}.1"
  ! grep -q 'OLDEST' "${LOG}.1" || false
  [ ! -e "${LOG}.2" ]
}

# End to end: a disagreement record rotates the log, then appends to a fresh
# one. Real mv, but DISAGREEMENT_LOG and the repo are under BATS_TEST_TMPDIR.
@test "a review run rotates an oversized log and appends to a fresh one" {
  local repo="${BATS_TEST_TMPDIR}/repo" mock="${BATS_TEST_TMPDIR}/mock" home="${BATS_TEST_TMPDIR}/home"
  git -C "${BATS_TEST_TMPDIR}" init -q repo
  git -C "${repo}" config user.email t@t
  git -C "${repo}" config user.name t
  printf 'echo a\n' >"${repo}/a.sh"
  git -C "${repo}" add a.sh
  GIT_CONFIG_GLOBAL=/dev/null git -C "${repo}" commit -q -m init
  printf 'echo b\n' >>"${repo}/a.sh"
  git -C "${repo}" add a.sh
  git -C "${repo}" config review.disagreementLogMaxBytes 100
  mkdir -p "${home}/.claude/plugins/marketplaces/t/agents" "${mock}"
  touch "${home}/.claude/plugins/marketplaces/t/agents/adversarial-reviewer.md"
  # code-reviewer blocks, adversarial passes, the arbiter (--allowedTools) confirms.
  cat >"${mock}/claude" <<'EOF'
#!/usr/bin/env bash
agent="" prev="" arb=false
for a in "$@"; do
  [[ "$a" == "--version" ]] && { echo mock; exit 0; }
  [[ "$prev" == "--agent" ]] && agent="$a"
  [[ "$a" == "--allowedTools" ]] && arb=true
  prev="$a"
done
cat >/dev/null
if [[ "${arb}" == true ]]; then
  so='{"ruling":"CONFIRMED","reason":"ROTATION_TEST_RECORD"}'
elif [[ "${agent}" == *adversarial* ]]; then
  so='{"verdict":"PASS","blocking":false,"findings":[]}'
else
  so='{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"a.sh:2","issue":"bad echo"}]}'
fi
jq -nc --argjson so "${so}" '{type:"result",subtype:"success",is_error:false,result:($so|tojson),structured_output:$so}'
EOF
  chmod +x "${mock}/claude"
  local gitdir="${repo}/.git"
  printf '%0200d\n' 0 >"${gitdir}/reviewer-disagreements.log"

  # setup exported a stub mv and a temp log; this run must use the real defaults.
  run bash -c 'cd "$1" && git diff --cached | env -u DISAGREEMENT_LOG -u REVIEW_MV_BIN HOME="$2" CLAUDE_CLI="$3" GIT_CONFIG_GLOBAL=/dev/null bash "$4"' \
    _ "${repo}" "${home}" "${mock}/claude" "${SCRIPT}"
  [ "$status" -ne 0 ]
  [ -s "${gitdir}/reviewer-disagreements.log.1" ]
  ! grep -q 'ROTATION_TEST_RECORD' "${gitdir}/reviewer-disagreements.log.1" || false
  grep -q 'ROTATION_TEST_RECORD' "${gitdir}/reviewer-disagreements.log"
  [ "$(head -1 "${gitdir}/reviewer-disagreements.log" | cut -c1-28)" = "=== REVIEWER DISAGREEMENT 20" ]
}
