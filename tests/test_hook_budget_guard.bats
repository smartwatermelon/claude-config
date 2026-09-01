#!/usr/bin/env bats
# Tests for ~/.claude/scripts/hook-budget-guard.sh
#
# The guard is a spend circuit-breaker on Stop and SubagentStop, built after
# session 91ef0da0 (huddle-transcribe, 2026-08-31) cost $42.04 with no loop
# present -- 51.2M cache-read tokens against 271K output, a 189:1 ratio.
#
# WHAT THESE TESTS ARE DEFENDING (the tripwires that matter):
#
#   1. The dedup MUST hold. The transcript stores retried/streamed requests
#      under a repeated requestId (65 twice, 17 three times in 91ef0da0). If
#      dedup breaks, the guard silently fires at ~half its stated ceiling and
#      starts blocking cheap sessions. "dedup: repeated requestId counted
#      once" is the canary -- it is written so it FAILS if the group_by is
#      removed, rather than passing for the wrong reason.
#
#   2. The release valve MUST hold. Claude Code caps consecutive
#      Stop/SubagentStop blocks at CLAUDE_CODE_STOP_HOOK_BLOCK_CAP??8
#      (verified in the v2.1.252 binary; the cap covers BOTH events). If the
#      hook ignores stop_hook_active it gets overridden by the harness -- the
#      block stops working precisely when it is needed -- and each wasted
#      block costs a full-context turn, making the guard itself the leak.
#
#   3. Every failure path MUST fail OPEN. A budget guard that crashes into a
#      block would halt all work in every repo. Unreadable, missing, empty,
#      truncated, and non-JSON inputs all have to exit 0.
#
# Run: bats ~/.claude/tests/test_hook_budget_guard.bats

HOOK="${BATS_TEST_DIRNAME}/../scripts/hook-budget-guard.sh"

setup() {
  TMPD="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMPD}"
}

# Write a transcript of N entries, each carrying `tokens` cache-read tokens
# under a DISTINCT requestId. Total spend is therefore n * tokens.
_write_transcript() {
  local path="$1" n="$2" tokens="$3" i
  : >"${path}"
  for ((i = 1; i <= n; i++)); do
    jq -nc --arg r "req-${i}" --argjson t "${tokens}" \
      '{requestId:$r, message:{usage:{cache_read_input_tokens:$t}}}' >>"${path}"
  done
}

_stop_input() {
  jq -nc --arg p "$1" --argjson active "${2:-false}" \
    '{hook_event_name:"Stop", transcript_path:$p, stop_hook_active:$active}'
}

_subagent_input() {
  jq -nc --arg p "$1" --argjson active "${2:-false}" \
    '{hook_event_name:"SubagentStop", agent_type:"general-purpose",
      agent_transcript_path:$p, stop_hook_active:$active}'
}

# --- Stop: hard ceiling ------------------------------------------------------

@test "stop: blocks when main-thread spend exceeds the ceiling" {
  _write_transcript "${TMPD}/t.jsonl" 10 1000 # 10,000
  run env BUDGET_SESSION_TOKENS=9000 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *'SESSION BUDGET EXCEEDED'* ]]
}

@test "stop: allows when spend is under the ceiling" {
  _write_transcript "${TMPD}/t.jsonl" 10 1000 # 10,000
  run env BUDGET_SESSION_TOKENS=11000 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "stop: block message tells the model to stop, not to keep working" {
  _write_transcript "${TMPD}/t.jsonl" 10 1000
  run env BUDGET_SESSION_TOKENS=9000 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")'"
  # A budget block that reads as "try harder" would deepen the hole it is
  # digging out of. It must route to the human and to a fresh session.
  [[ "${output}" == *'Do NOT keep working'* ]]
  [[ "${output}" == *'FRESH session'* ]]
}

# --- Stop: soft warning ------------------------------------------------------

@test "stop: soft warn emits systemMessage JSON and does NOT block" {
  _write_transcript "${TMPD}/t.jsonl" 10 1000 # 10,000
  run env BUDGET_SESSION_TOKENS=99999999 BUDGET_SESSION_WARN_TOKENS=5000 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")'"
  [ "${status}" -eq 0 ]
  # Must be valid JSON carrying systemMessage, or the harness drops it.
  run bash -c "env BUDGET_SESSION_TOKENS=99999999 BUDGET_SESSION_WARN_TOKENS=5000 \"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")' | jq -r '.systemMessage'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'Session spend'* ]]
}

@test "stop: below the warn threshold is completely silent" {
  _write_transcript "${TMPD}/t.jsonl" 2 1000 # 2,000
  run env BUDGET_SESSION_TOKENS=99999999 BUDGET_SESSION_WARN_TOKENS=50000 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl")'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# --- SubagentStop ------------------------------------------------------------

@test "subagent: blocks when one agent exceeds its ceiling" {
  _write_transcript "${TMPD}/a.jsonl" 10 1000 # 10,000
  run env BUDGET_SUBAGENT_TOKENS=9000 \
    bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/a.jsonl")'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *'SUBAGENT BUDGET EXCEEDED'* ]]
  [[ "${output}" == *'general-purpose'* ]]
}

@test "subagent: allows an agent under its ceiling" {
  _write_transcript "${TMPD}/a.jsonl" 3 1000 # 3,000
  run env BUDGET_SUBAGENT_TOKENS=5000 \
    bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/a.jsonl")'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "subagent: block message forbids re-dispatching a replacement agent" {
  _write_transcript "${TMPD}/a.jsonl" 10 1000
  run env BUDGET_SUBAGENT_TOKENS=9000 \
    bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/a.jsonl")'"
  # The 91ef0da0 pattern: kill/finish an agent, immediately dispatch another
  # cold one that re-reads ~40K of instructions before doing any work.
  [[ "${output}" == *'re-dispatch'* ]]
}

@test "subagent: does not consult the main-thread ceiling" {
  # Cross-wiring the two ceilings would make a cheap agent trip the session
  # limit, or vice versa. Session ceiling is set to 1 here and must be inert.
  _write_transcript "${TMPD}/a.jsonl" 3 1000
  run env BUDGET_SUBAGENT_TOKENS=5000 BUDGET_SESSION_TOKENS=1 \
    bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/a.jsonl")'"
  [ "${status}" -eq 0 ]
}

# --- The release valve (harness block cap) -----------------------------------

@test "release valve: stop_hook_active=true allows Stop even at ceiling 1" {
  _write_transcript "${TMPD}/t.jsonl" 10 1000
  run env BUDGET_SESSION_TOKENS=1 BUDGET_SESSION_WARN_TOKENS=1 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/t.jsonl" true)'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "release valve: stop_hook_active=true allows SubagentStop at ceiling 1" {
  _write_transcript "${TMPD}/a.jsonl" 10 1000
  run env BUDGET_SUBAGENT_TOKENS=1 \
    bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/a.jsonl" true)'"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

# --- Dedup: the load-bearing tripwire ---------------------------------------

@test "dedup: repeated requestId is counted once, not N times" {
  # Three entries, one requestId, 1000 tokens each. True spend is 1000.
  # Ceiling 1500 therefore must ALLOW. If dedup regresses, the sum becomes
  # 3000, 3000 > 1500, and this test fails with a block -- which is exactly
  # the alarm we want, because a silent 3x overcount would fire the guard on
  # sessions that spent nothing unusual.
  : >"${TMPD}/dup.jsonl"
  for i in 1 2 3; do
    jq -nc --arg u "u${i}" \
      '{requestId:"req-DUP", uuid:$u, message:{usage:{cache_read_input_tokens:1000}}}' \
      >>"${TMPD}/dup.jsonl"
  done
  run env BUDGET_SESSION_TOKENS=1500 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/dup.jsonl")'"
  [ "${status}" -eq 0 ]
}

@test "dedup: the deduped total is still counted (guard is not dead)" {
  # Same fixture as above against a ceiling of 900. A guard that returned 0
  # for everything would pass the previous test for the wrong reason; this
  # pins the other side, so the pair together prove the value is 1000.
  : >"${TMPD}/dup.jsonl"
  for i in 1 2 3; do
    jq -nc --arg u "u${i}" \
      '{requestId:"req-DUP", uuid:$u, message:{usage:{cache_read_input_tokens:1000}}}' \
      >>"${TMPD}/dup.jsonl"
  done
  run env BUDGET_SESSION_TOKENS=900 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/dup.jsonl")'"
  [ "${status}" -eq 2 ]
}

@test "dedup: distinct requestIds still sum" {
  _write_transcript "${TMPD}/d.jsonl" 3 1000 # 3 distinct ids -> 3000
  run env BUDGET_SESSION_TOKENS=2500 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/d.jsonl")'"
  [ "${status}" -eq 2 ]
}

@test "dedup: entries lacking requestId fall back to uuid, counted once each" {
  # No requestId at all. Both entries must count (distinct uuids), so 2000
  # exceeds a 1500 ceiling. If the fallback dropped them, spend would read 0
  # and the guard would never fire on this shape of transcript.
  {
    jq -nc '{uuid:"x1", message:{usage:{cache_read_input_tokens:1000}}}'
    jq -nc '{uuid:"x2", message:{usage:{cache_read_input_tokens:1000}}}'
  } >"${TMPD}/nr.jsonl"
  run env BUDGET_SESSION_TOKENS=1500 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/nr.jsonl")'"
  [ "${status}" -eq 2 ]
}

# --- Token accounting -------------------------------------------------------

@test "accounting: sums all four usage fields, not just cache_read" {
  # 250 each across the four fields = 1000 total, over a 900 ceiling.
  jq -nc '{requestId:"r1", message:{usage:{
      cache_read_input_tokens:250, cache_creation_input_tokens:250,
      input_tokens:250, output_tokens:250}}}' >"${TMPD}/four.jsonl"
  run env BUDGET_SESSION_TOKENS=900 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/four.jsonl")'"
  [ "${status}" -eq 2 ]
}

@test "accounting: entries with no usage object are ignored" {
  {
    jq -nc '{requestId:"r1", message:{usage:{cache_read_input_tokens:1000}}}'
    jq -nc '{requestId:"r2", message:{role:"user", content:"hi"}}'
    jq -nc '{type:"system", subtype:"info"}'
  } >"${TMPD}/mixed.jsonl"
  run env BUDGET_SESSION_TOKENS=1500 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/mixed.jsonl")'"
  [ "${status}" -eq 0 ]
}

# --- Fail-open paths --------------------------------------------------------

@test "fail-open: truncated final line still counts the complete entries" {
  # The transcript is written live and is NOT guaranteed flushed when the
  # hook fires, so a half-written last line is the normal case, not an edge.
  jq -nc '{requestId:"r1", message:{usage:{cache_read_input_tokens:9000}}}' \
    >"${TMPD}/tr.jsonl"
  printf 'not json at all\n' >>"${TMPD}/tr.jsonl"
  printf '{"requestId":"r2","message":{"usage":{"cache_read_' >>"${TMPD}/tr.jsonl"
  run env BUDGET_SESSION_TOKENS=8000 BUDGET_SESSION_WARN_TOKENS=99999999 \
    bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/tr.jsonl")'"
  [ "${status}" -eq 2 ]
}

@test "fail-open: missing transcript file allows the stop" {
  run bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/does-not-exist.jsonl")'"
  [ "${status}" -eq 0 ]
}

@test "fail-open: absent transcript_path allows the stop" {
  run bash -c "\"${HOOK}\" <<<'{\"hook_event_name\":\"Stop\"}'"
  [ "${status}" -eq 0 ]
}

@test "fail-open: SubagentStop without agent_transcript_path allows" {
  run bash -c "\"${HOOK}\" <<<'{\"hook_event_name\":\"SubagentStop\",\"agent_type\":\"x\"}'"
  [ "${status}" -eq 0 ]
}

@test "fail-open: empty transcript file allows the stop" {
  : >"${TMPD}/empty.jsonl"
  run bash -c "\"${HOOK}\" <<<'$(_stop_input "${TMPD}/empty.jsonl")'"
  [ "${status}" -eq 0 ]
}

@test "fail-open: empty stdin neither hangs nor blocks" {
  run bash -c "\"${HOOK}\" </dev/null"
  [ "${status}" -eq 0 ]
}

@test "fail-open: unknown hook event is a no-op" {
  run bash -c "\"${HOOK}\" <<<'{\"hook_event_name\":\"PostToolUse\"}'"
  [ "${status}" -eq 0 ]
}

@test "fail-open: non-JSON stdin does not block" {
  run bash -c "\"${HOOK}\" <<<'garbage not json'"
  [ "${status}" -eq 0 ]
}

# --- Regression pin against the real incident -------------------------------

@test "incident 91ef0da0: default subagent ceiling would have caught the 19.2M agent" {
  # The fix agent spent 19.2M. The three other agents were 1.6M/2.1M/3.1M.
  # The 5M default must separate them: block the expensive one, ignore the
  # cheap ones. This pins the DEFAULT, so a future retune that lets the
  # 19.2M agent through fails here.
  _write_transcript "${TMPD}/big.jsonl" 20 1000000  # 20M
  run bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/big.jsonl")'"
  [ "${status}" -eq 2 ]

  _write_transcript "${TMPD}/small.jsonl" 3 1000000 # 3M, like the reviewers
  run bash -c "\"${HOOK}\" <<<'$(_subagent_input "${TMPD}/small.jsonl")'"
  [ "${status}" -eq 0 ]
}

# --- Portable replay of the incident (no machine-local state required) -------
#
# WHY THESE FIXTURES EXIST. The claim "this guard would have blocked the one
# runaway agent and left the other four alone" was originally verified against
# the real subagent transcripts under ~/.claude/projects/. Those exist on
# exactly one machine and are not committable (they contain session content).
# On any other checkout the central claim of this guard would have been
# unverifiable -- taken on faith from a commit message.
#
# tests/fixtures/incident-91ef0da0/ holds five synthetic transcripts, one per
# agent from the measured session, whose requestId-deduped totals reproduce
# the real per-agent spend (19.4M / 3.7M / 3.2M / 2.2M / 1.7M). Each also
# carries one duplicated requestId, mirroring how the real transcript stores
# retried requests, so the fixtures exercise dedup as well as the thresholds.
#
# Confirmed equivalent: running the guard against the real transcripts and
# against these fixtures produces identical verdicts at the 5M default.

FIXTURES="${BATS_TEST_DIRNAME}/fixtures/incident-91ef0da0"

@test "incident replay: only the runaway agent is blocked at the 5M default" {
  local blocked=0 allowed=0 f
  for f in "${FIXTURES}"/*.jsonl; do
    run bash -c "\"${HOOK}\" <<<'$(_subagent_input "${f}")'"
    if [ "${status}" -eq 2 ]; then
      blocked=$((blocked + 1))
    else
      allowed=$((allowed + 1))
    fi
  done
  # Exactly one of the five agents was the runaway. If a retune makes this 0,
  # the guard has stopped catching the incident it was built for; if it makes
  # this 2+, it has started blocking legitimate review fan-out.
  [ "${blocked}" -eq 1 ]
  [ "${allowed}" -eq 4 ]
}

@test "incident replay: the runaway agent is the fix-findings agent" {
  run bash -c "\"${HOOK}\" <<<'$(_subagent_input "${FIXTURES}/agent-a78eb5a7-fix-findings.jsonl")'"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *'19.4M'* ]]
}

@test "incident replay: the two reviewers are left alone" {
  # These are the agents that did their job at reasonable cost. A guard that
  # blocks them is worse than no guard, because it would train the operator
  # to raise the ceiling permanently.
  for f in agent-a360be39-security-reviewer agent-a962c964-adversarial; do
    run bash -c "\"${HOOK}\" <<<'$(_subagent_input "${FIXTURES}/${f}.jsonl")'"
    [ "${status}" -eq 0 ]
  done
}

@test "incident replay: fixtures dedup their repeated requestId" {
  # Each fixture repeats its first entry verbatim. If dedup regressed, every
  # fixture total would inflate and the cheapest agent (1.7M) would cross a
  # 2M ceiling. It must not.
  run bash -c "env BUDGET_SUBAGENT_TOKENS=2000000 \"${HOOK}\" <<<'$(_subagent_input "${FIXTURES}/agent-a6447e0d-build-1-killed.jsonl")'"
  [ "${status}" -eq 0 ]
}
