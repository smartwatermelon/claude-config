#!/usr/bin/env bats
# Tests for normalize_agent_response() in hooks/run-review.sh.
#
# Why this exists: smartwatermelon/claude-config#450. The function's else
# branch — taken when .structured_output.blocking is not a JSON boolean —
# printed .result alone and discarded .structured_output.verdict. When the
# response also carried no `VERDICT:` line in its prose (routine under
# --json-schema, where the model is constrained to a tool call and .result is
# narration or the serialized object), the gate received bare prose,
# parse_verdict returned "", and a clean PASS hard-blocked the commit.
#
# The verdict and the blocking boolean are INDEPENDENT fields. A missing
# boolean is not a reason to discard a present verdict.
#
# The first attempt at this fix RECOVERED the verdict by prepending a
# `VERDICT:` line onto `.result` — and opened a fail-open. When `.result` is
# the serialized object (the normal shape under --json-schema), the "prose"
# handed downstream is JSON, and has_blocking_severity() cannot match
# `"severity":"BLOCKING"`: the quote between the colon and the keyword defeats
# its pattern. A reviewer reporting FAIL with a BLOCKING finding, slipping only
# on the boolean's TYPE, then exited 0 where the pre-fix code exited 1.
#
# So this branch RENDERS from .structured_output.findings[] using the same
# renderer the boolean-present path uses, and blocks by default on a recovered
# FAIL/REVISE that renders no blocking severity. These tests pin both the
# recovery and the fail-closed property — several assert on the blocking
# REASON, not merely on a nonzero status, because "blocked" and "blocked for
# the right reason" are not the same outcome.
#
# Run: bats tests/test_normalize_agent_response.bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
  # Source only the functions under test. The script as a whole executes a
  # full review when run, so it cannot be sourced (issue #450 records this
  # obstacle). Each function body's closing brace is at column 0.
  BLUE=; GREEN=; YELLOW=; RED=; NC=
  export BLUE GREEN YELLOW RED NC
  _NL=$'\n'
  STRUCTURED_MARKER="__REVIEW_BLOCKING__"
  FIX_NOW_MARKER="__REVIEW_FIX_NOW__"
  # Stub the loggers rather than slicing them out by line number: a hardcoded
  # range silently evals the wrong lines the moment anything is inserted above
  # it, and this very fix inserts ~20 lines near the top of the file. No test
  # here asserts on log output.
  log_info() { :; }
  log_success() { :; }
  log_warn() { :; }
  log_error() { :; }
  local _fn
  for _fn in parse_verdict has_blocking_severity extract_structured_blocking \
    attach_structured_blocking read_structured_blocking extract_fix_now \
    attach_fix_now strip_structured_blocking output_blocks \
    render_structured_prose extract_json_envelope normalize_agent_response; do
    eval "$(sed -n "/^${_fn}() {/,/^}/p" "${SCRIPT}")"
  done
}

# --- The #450 regression: verdict survives a non-boolean blocking field ---

@test "#450: blocking as string \"false\" with narration prose still yields PASS" {
  # The exact captured shape: stop_reason tool_use, schema not fully honored
  # on the boolean, .result carrying narration rather than a VERDICT block.
  raw='{"stop_reason":"tool_use","result":"I reviewed the diff. The changes are clean and correct.","structured_output":{"verdict":"PASS","blocking":"false","findings":[]}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#450: blocking absent entirely still yields the structured verdict" {
  raw='{"result":"{\"verdict\":\"PASS\"}","structured_output":{"verdict":"PASS","findings":[]}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#450: blocking null still yields the structured verdict" {
  raw='{"result":"Reviewed, nothing to report.","structured_output":{"verdict":"PASS","blocking":null}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#450: a FAIL verdict survives a non-boolean blocking field too" {
  raw='{"result":"Reviewed. There is a problem here.","structured_output":{"verdict":"FAIL","blocking":"true"}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "FAIL" ]
}

# --- Fail-closed must survive the fix ---

@test "no boolean means no sentinel: blocking prose still blocks" {
  # The reviewer did not answer the boolean, so output_blocks() must fall back
  # to has_blocking_severity() over the prose rather than silently passing.
  raw='{"result":"Found a real defect.\nSEVERITY: BLOCKING","structured_output":{"verdict":"FAIL","blocking":null}}'
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -eq 0 ]
}

@test "no boolean and no blocking prose does not block" {
  raw='{"result":"Reviewed, nothing to report.","structured_output":{"verdict":"PASS","blocking":null}}'
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -ne 0 ]
}

@test "no boolean means no structured sentinel is attached" {
  raw='{"result":"Reviewed, nothing to report.","structured_output":{"verdict":"PASS","blocking":null}}'
  run read_structured_blocking "$(normalize_agent_response "${raw}")"
  [ -z "${output}" ]
}

# --- Existing behavior that must not regress ---

@test "control: a real boolean still takes the rendering path and attaches a sentinel" {
  raw='{"result":"{\"verdict\":\"PASS\",\"blocking\":false,\"findings\":[]}","structured_output":{"verdict":"PASS","blocking":false,"findings":[]}}'
  norm=$(normalize_agent_response "${raw}")
  run read_structured_blocking "${norm}"
  [ "${output}" = "false" ]
  run parse_verdict "${norm}"
  [ "${output}" = "PASS" ]
}

@test "prose that already carries a VERDICT line is not double-prefixed" {
  raw='{"result":"VERDICT: FAIL\nSEVERITY: BLOCKING","structured_output":{"verdict":"FAIL","blocking":null}}'
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^VERDICT:'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "a markdown-emphasized VERDICT in prose is recognized, not double-prefixed" {
  # The guard uses the same tolerant pattern as the renderer branch, so
  # `**VERDICT:** FAIL` must count as prose that already has a verdict.
  raw='{"result":"**VERDICT:** FAIL\nSEVERITY: BLOCKING","structured_output":{"verdict":"FAIL","blocking":null}}'
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -ci 'VERDICT'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "an envelope with no structured_output at all passes prose through unchanged" {
  raw='{"result":"Looks good to me."}'
  run normalize_agent_response "${raw}"
  [ "${output}" = "Looks good to me." ]
}

@test "neither a boolean nor a usable verdict leaves prose unchanged (gate blocks)" {
  raw='{"result":"Looks good to me.","structured_output":{"blocking":null}}'
  norm=$(normalize_agent_response "${raw}")
  [ "${norm}" = "Looks good to me." ]
  run parse_verdict "${norm}"
  [ -z "${output}" ]
}

# --- The fail-open the first attempt at this fix introduced ---

@test "#450 fail-open: serialized-object .result with FAIL + BLOCKING still blocks" {
  # THE regression guard. Prepending a verdict onto this input produced
  # `VERDICT: FAIL` above a JSON blob that no severity pattern matches, so the
  # gate saw FAIL-with-no-blocking-finding and exited 0. Rendering emits a real
  # `SEVERITY: BLOCKING` line for the fallback to match.
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"breaks under set -e"}]}'
  raw=$(jq -n --argjson so "${so}" '{result:($so|tojson),structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#450 fail-open: the rendered prose carries a real SEVERITY: BLOCKING line" {
  # Assert the MECHANISM, not just the outcome: output_blocks() can only fall
  # back correctly if the prose it greps has a matchable severity line.
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"breaks under set -e"}]}'
  raw=$(jq -n --argjson so "${so}" '{result:($so|tojson),structured_output:$so}')
  run has_blocking_severity "$(normalize_agent_response "${raw}")"
  [ "${status}" -eq 0 ]
}

@test "#450 fail-open: a raw serialized object is NOT matched by has_blocking_severity" {
  # Pins the premise the above rests on. If this ever starts matching, the
  # renderer is no longer load-bearing and these tests would pass vacuously.
  run has_blocking_severity '{"findings":[{"severity":"BLOCKING"}]}'
  [ "${status}" -ne 0 ]
}

@test "#450: a recovered FAIL with no findings blocks rather than passing as a warning" {
  raw='{"result":"Something is wrong here.","structured_output":{"verdict":"FAIL","blocking":null}}'
  norm=$(normalize_agent_response "${raw}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#450: a recovered REVISE with no findings also blocks" {
  raw='{"result":"Some concerns.","structured_output":{"verdict":"REVISE","blocking":null}}'
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -eq 0 ]
}

@test "#450: a recovered PASS with no findings does NOT get a synthetic block" {
  # The blocking-by-default rule must apply only to FAIL/REVISE. A PASS that
  # renders no findings is a clean pass, which is the whole point of #450.
  raw='{"result":"Reviewed, nothing to report.","structured_output":{"verdict":"PASS","blocking":null}}'
  run has_blocking_severity "$(normalize_agent_response "${raw}")"
  [ "${status}" -ne 0 ]
}

@test "#450: a structured FAIL is not overridden by a prose verdict the guard misses" {
  # parse_verdict is PASS-anywhere-wins, and the "already has a verdict" guard
  # is line-anchored, so a bulleted `- VERDICT: PASS` is not recognized as
  # prose-with-a-verdict. Prepending left both lines in the output and the
  # prose PASS won. Rendering does not carry the prose forward at all.
  raw=$(jq -n --argjson so '{"verdict":"FAIL","blocking":"true"}' \
    --arg p '- VERDICT: PASS
all good' '{result:$p,structured_output:$so}')
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "FAIL" ]
}

@test "#450: a blockquoted prose verdict likewise cannot override structured FAIL" {
  raw=$(jq -n --argjson so '{"verdict":"FAIL","blocking":"true"}' \
    --arg p '> VERDICT: PASS
all good' '{result:$p,structured_output:$so}')
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "FAIL" ]
}

# --- The #461 regression: non-JSON noise adjacent to the envelope ---
#
# A stray diagnostic line concatenated with the envelope makes EVERY jq in the
# parse path exit 5 (parse error), not 1 (key absent). normalize_agent_response
# then falls through its "not an envelope" branch and hands the gate the whole
# blob as prose, which carries no `VERDICT:` line, so a clean PASS blocked the
# push. Observed line, verbatim, from the #461 report:
#
#   Client.listTools() called but server does not advertise tools capability - returning empty list
#
# The fix extracts the envelope before parsing rather than suppressing any
# particular warning string: #89 showed this hazard recurs in new forms.

@test "#461: a trailing non-JSON line does not defeat the structured verdict" {
  raw='{"result":"{\"verdict\":\"PASS\"}","structured_output":{"verdict":"PASS","blocking":false,"findings":[]}}
Client.listTools() called but server does not advertise tools capability - returning empty list'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#461: a leading non-JSON line does not defeat the structured verdict" {
  raw='Client.listTools() called but server does not advertise tools capability - returning empty list
{"result":"{\"verdict\":\"PASS\"}","structured_output":{"verdict":"PASS","blocking":false,"findings":[]}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#461: noise around a FAIL envelope still blocks — recovery must not fail open" {
  so='{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"a.sh:1","issue":"broken","details":"very broken"}]}'
  raw="$(jq -nc --argjson so "${so}" '{result:($so|tojson),structured_output:$so}')
Client.listTools() called but server does not advertise tools capability - returning empty list"
  norm=$(normalize_agent_response "${raw}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#461: genuine non-envelope prose still passes through unchanged" {
  # The extraction must not invent an envelope out of prose that merely
  # contains braces. This degrades to the prose path, as before.
  raw='VERDICT: PASS
No blocking issues found. The { and } here are not an envelope.'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#461: extract_json_envelope returns the envelope from a contaminated blob" {
  raw='{"result":"ok","structured_output":{"verdict":"PASS"}}
Client.listTools() called but server does not advertise tools capability - returning empty list'
  # Note: not `run bash -c`, which forks a subshell that cannot see the
  # function sourced into this one.
  env=$(extract_json_envelope "${raw}")
  run jq -r '.structured_output.verdict' <<<"${env}"
  [ "${output}" = "PASS" ]
}

@test "#461: extract_json_envelope echoes input unchanged when no envelope is present" {
  run extract_json_envelope 'just some prose'
  [ "${output}" = "just some prose" ]
}

# --- Fail-closed properties of the recovery itself ---

@test "#461: prose QUOTING an envelope is not hijacked — a BLOCKING FAIL still blocks" {
  # The fail-open the recovery introduced before it was guarded. A reviewer
  # reviewing THIS file quotes an envelope in DETAILS as a matter of course.
  # Extracting unconditionally discarded the entire prose review in favour of
  # the quoted line, and a BLOCKING FAIL reached the gate as PASS.
  raw='VERDICT: FAIL
ISSUE: envelope handling is wrong
SEVERITY: BLOCKING
LOCATION: hooks/run-review.sh:630
DETAILS: for input
{"result":"x","structured_output":{"verdict":"PASS","blocking":false}}
the fast path returns early.'
  norm=$(normalize_agent_response "${raw}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#461: prose quoting an envelope keeps its own findings intact" {
  # Not merely "blocked" but "blocked for the right reason": the reviewer's
  # real finding must survive, not be replaced by the quoted envelope's.
  raw='VERDICT: FAIL
ISSUE: envelope handling is wrong
SEVERITY: BLOCKING
LOCATION: hooks/run-review.sh:630
DETAILS: quoting {"result":"x","structured_output":{"verdict":"PASS"}} here'
  norm=$(normalize_agent_response "${raw}")
  run has_blocking_severity "${norm}"
  [ "${status}" -eq 0 ]
  [[ "${norm}" == *"envelope handling is wrong"* ]]
}

@test "#461: a blocking envelope is not suppressed by a later PASS envelope" {
  # Precedence matters for a safety gate. "Last line wins" would let a PASS
  # appended after a real FAIL hide the FAIL. Not known to be reachable — the
  # CLI emits one envelope — but the gate must not depend on that.
  fail=$(jq -nc '{result:"x",structured_output:{verdict:"FAIL",blocking:true,findings:[{severity:"BLOCKING",location:"a:1",issue:"bad",details:"d"}]}}')
  pass=$(jq -nc '{result:"x",structured_output:{verdict:"PASS",blocking:false,findings:[]}}')
  norm=$(normalize_agent_response "${fail}
${pass}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#461: a FAIL verdict with a non-boolean blocking field still takes precedence" {
  # #450 established that `blocking` may be absent or a string. Precedence must
  # key on the verdict too, not on the boolean alone.
  fail=$(jq -nc '{result:"x",structured_output:{verdict:"FAIL",blocking:"true"}}')
  pass=$(jq -nc '{result:"x",structured_output:{verdict:"PASS",blocking:false,findings:[]}}')
  run parse_verdict "$(normalize_agent_response "${fail}
${pass}")"
  [ "${output}" = "FAIL" ]
}

@test "#461: a pretty-printed envelope with no noise is still parsed normally" {
  # The fast path handles this; only the line-based slow path cannot.
  raw=$(jq -n '{result:"{}",structured_output:{verdict:"PASS",blocking:false,findings:[]}}')
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#461: precedence holds with a serialized .result, the shape seen under --json-schema" {
  # Same property as the test above, with the .result the CLI actually emits
  # under --json-schema (the serialized object) rather than a stub.
  so='{"verdict":"FAIL","blocking":true,"findings":[{"severity":"BLOCKING","location":"a:1","issue":"bad","details":"d"}]}'
  fail=$(jq -nc --argjson so "${so}" '{result:($so|tojson),structured_output:$so}')
  pass=$(jq -nc '{result:"{}",structured_output:{verdict:"PASS",blocking:false,findings:[]}}')
  norm=$(normalize_agent_response "${fail}
${pass}")
  run parse_verdict "${norm}"
  [ "${output}" = "FAIL" ]
  run output_blocks "${norm}"
  [ "${status}" -eq 0 ]
}

@test "#461: a contaminated pretty-printed envelope fails CLOSED, not open" {
  # Documented limit: a multi-line envelope plus noise is unrecoverable by a
  # line-based scan. It must yield NO verdict — which is what makes the caller
  # block as unparseable — never a spurious PASS.
  raw="$(jq -n '{result:"{}",structured_output:{verdict:"FAIL",blocking:true,findings:[{severity:"BLOCKING",location:"a:1",issue:"bad",details:"d"}]}}')
Client.listTools() called but server does not advertise tools capability - returning empty list"
  run parse_verdict "$(normalize_agent_response "${raw}")"
  # Empty, not merely non-PASS: an empty verdict is the unparseable signal the
  # gate blocks on.
  [ -z "${output}" ]
}

@test "render_structured_prose emits nothing for an envelope with no structured output" {
  run render_structured_prose '{"result":"hi"}'
  [ -z "${output}" ]
}

@test "render_structured_prose excludes FIX_NOW findings from the block" {
  so='{"verdict":"PASS","blocking":false,"findings":[{"severity":"FIX_NOW","location":"a:1","issue":"quote it","details":"add quotes"},{"severity":"WARNING","location":"b:2","issue":"nit","details":"n/a"}]}'
  raw=$(jq -n --argjson so "${so}" '{result:($so|tojson),structured_output:$so}')
  out=$(render_structured_prose "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'SEVERITY: FIX_NOW'" _ "${out}"
  [ "${output}" = "0" ]
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'SEVERITY: WARNING'" _ "${out}"
  [ "${output}" = "1" ]
}

@test "an unrecognized verdict spelling is not invented into a verdict" {
  raw='{"result":"Reviewed.","structured_output":{"verdict":"MAYBE","blocking":null}}'
  norm=$(normalize_agent_response "${raw}")
  [ "${norm}" = "Reviewed." ]
  run parse_verdict "${norm}"
  [ -z "${output}" ]
}

@test "a lowercase structured verdict is normalized to upper case" {
  raw='{"result":"Reviewed.","structured_output":{"verdict":"pass","blocking":null}}'
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "non-JSON input still degrades to the prose path" {
  run normalize_agent_response "VERDICT: PASS"
  [ "${output}" = "VERDICT: PASS" ]
}

@test "empty input is handed back untouched" {
  run normalize_agent_response ""
  [ -z "${output}" ]
}

# --- The prose-priority path: same fail-open class, one branch over ---

@test "#450: prose with a VERDICT line does not discard a structured BLOCKING finding" {
  # Returning .result bare on this path threw away .structured_output entirely.
  # A reviewer whose prose reads clean but whose structured findings carry
  # BLOCKING passed the gate, with no sentinel to rescue it downstream.
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"breaks under set -e"}]}'
  raw=$(jq -n --argjson so "${so}" --arg p 'VERDICT: FAIL
Something minor.' '{result:$p,structured_output:$so}')
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -eq 0 ]
}

@test "#450: prose claiming PASS cannot suppress a structured BLOCKING finding" {
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"breaks under set -e"}]}'
  raw=$(jq -n --argjson so "${so}" --arg p 'VERDICT: PASS
Looks fine.' '{result:$p,structured_output:$so}')
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -eq 0 ]
}

@test "#450: the carried-over finding keeps the reviewer's real location text" {
  # Blocking is not enough — a hard block with its diagnostic content stripped
  # is the worst kind to receive.
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"breaks under set -e"}]}'
  raw=$(jq -n --argjson so "${so}" --arg p 'VERDICT: FAIL
Something minor.' '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'foo.sh:2'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "#450: carrying findings across does not leave two VERDICT lines" {
  so='{"verdict":"FAIL","blocking":"true","findings":[{"severity":"BLOCKING","location":"foo.sh:2","issue":"real defect","details":"d"}]}'
  raw=$(jq -n --argjson so "${so}" --arg p 'VERDICT: FAIL
Something minor.' '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^VERDICT:'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "#450: a clean PASS on the prose path gets no synthetic block" {
  so='{"verdict":"PASS","blocking":"false","findings":[]}'
  raw=$(jq -n --argjson so "${so}" --arg p 'VERDICT: PASS
Looks fine.' '{result:$p,structured_output:$so}')
  run output_blocks "$(normalize_agent_response "${raw}")"
  [ "${status}" -ne 0 ]
}

# --- NON_BLOCKING_ISSUE filing input must survive (regression guard) ---

@test "#450: an NBI-only .result keeps its blocks instead of being rendered over" {
  # The prose-priority guard used to key on a VERDICT line alone. A .result
  # carrying only NON_BLOCKING_ISSUE blocks has none, so it fell through to the
  # renderer and the blocks were destroyed — silently disabling
  # pre-existing-defect filing in codebase mode.
  nbi='NON_BLOCKING_ISSUE:
TITLE: a pre-existing nit
LOCATION: foo.sh:9
DETAILS: unquoted expansion
END_ISSUE'
  raw=$(jq -n --argjson so '{"verdict":"PASS","blocking":"false","findings":[]}' \
    --arg p "${nbi}" '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^NON_BLOCKING_ISSUE:'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "#450: an NBI-only .result still gains a parseable VERDICT line" {
  # Preserving the blocks is not enough: with no VERDICT line the gate reads
  # the whole review as unparseable and hard-blocks, which is #450 itself.
  nbi='NON_BLOCKING_ISSUE:
TITLE: a pre-existing nit
LOCATION: foo.sh:9
DETAILS: unquoted expansion
END_ISSUE'
  raw=$(jq -n --argjson so '{"verdict":"PASS","blocking":"false","findings":[]}' \
    --arg p "${nbi}" '{result:$p,structured_output:$so}')
  run parse_verdict "$(normalize_agent_response "${raw}")"
  [ "${output}" = "PASS" ]
}

@test "#450: END_ISSUE terminator survives, so the block still parses" {
  nbi='NON_BLOCKING_ISSUE:
TITLE: a pre-existing nit
LOCATION: foo.sh:9
DETAILS: unquoted expansion
END_ISSUE'
  raw=$(jq -n --argjson so '{"verdict":"PASS","blocking":"false","findings":[]}' \
    --arg p "${nbi}" '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c '^END_ISSUE$'" _ "${norm}"
  [ "${output}" = "1" ]
}

# --- Reviewer's own finding text must not be replaced by a placeholder ---

@test "#450: real finding prose is preserved, not swapped for a synthetic reason" {
  # findings[] is empty but .result carries a genuine ISSUE/SEVERITY block with
  # no leading VERDICT line, so it reaches the renderer. Rendering alone would
  # emit a verdict plus a synthetic reason while the real location and
  # explanation vanished.
  raw=$(jq -n --argjson so '{"verdict":"FAIL","blocking":"true","findings":[]}' \
    --arg p 'ISSUE: a real defect
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: this breaks under set -e' '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'this breaks under set -e'" _ "${norm}"
  [ "${output}" = "1" ]
}

@test "#450: ...and that case is not given a redundant synthetic block on top" {
  raw=$(jq -n --argjson so '{"verdict":"FAIL","blocking":"true","findings":[]}' \
    --arg p 'ISSUE: a real defect
SEVERITY: BLOCKING
LOCATION: foo.sh:2
DETAILS: this breaks under set -e' '{result:$p,structured_output:$so}')
  norm=$(normalize_agent_response "${raw}")
  run bash -c "printf '%s\n' \"\$1\" | grep -c 'Treated as blocking because'" _ "${norm}"
  [ "${output}" = "0" ]
}
