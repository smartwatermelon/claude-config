#!/usr/bin/env bats
# Tests that reviewer prompts do not instruct a reviewer to run commands it
# has no tools to run.
#
# Why this exists: the VERIFIABLE CLAIMS rule offered two branches — (1) run
# the command that checks the claim and record it in a VERIFIED: field, or
# (2) soften the claim into a question. Branch 1 is impossible for both
# reviewers here: the codebase reviewer is invoked with
# --allowedTools "Read,Grep,Glob" and the pre-merge reviewer with --tools ""
# (no tools at all). Every finding therefore had to fall to branch 2, and
# nothing required that it did, so flat declarative claims about runtime
# behavior went out unlabelled and unchecked. Issue #412, motivating case #410.
#
# These assertions are invariants about the PROMPT TEXT, not about model
# output. They fail if someone re-adds a "run the command" instruction to a
# reviewer that cannot run one, or grants tool access without revisiting the
# prompt that assumes their absence.
#
# Run: bats ~/.claude/tests/test_reviewer_prompt_tool_honesty.bats

RUN_REVIEW="${BATS_TEST_DIRNAME}/../hooks/run-review.sh"
PRE_MERGE="${BATS_TEST_DIRNAME}/../hooks/pre-merge-review.sh"

@test "codebase reviewer is still invoked without Bash" {
  # The prompt rules below are written for exactly this tool set. If this
  # assertion fails, the reviewer gained (or lost) tools and the VERIFIABLE
  # CLAIMS wording must be revisited rather than silently left stale.
  grep -q -- '--allowedTools "Read,Grep,Glob"' "${RUN_REVIEW}"
}

@test "pre-merge reviewer is still invoked with no tools" {
  grep -q -- '--tools ""' "${PRE_MERGE}"
}

@test "codebase prompt states the reviewer cannot run commands" {
  grep -q 'You cannot run commands' "${RUN_REVIEW}"
  grep -q 'ONLY TOOLS ARE Read, Grep, AND Glob' "${RUN_REVIEW}"
}

@test "codebase prompt makes the softened form mandatory for behavior claims" {
  # Branch 2 must be stated as an obligation, not an escape hatch taken only
  # when branch 1 is unavailable.
  grep -q 'SOFTENED FORM IS MANDATORY, NOT A FALLBACK' "${RUN_REVIEW}"
}

@test "codebase prompt no longer tells the reviewer to run a one-liner" {
  # The old wording closed with "Run the one-liner, or ask the question
  # instead of making the assertion" and illustrated VERIFIED: with a `gh api`
  # invocation — both instructions to execute something it cannot execute.
  ! grep -q 'Run the one-liner' "${RUN_REVIEW}"
  ! grep -q 'VERIFIED: gh api' "${RUN_REVIEW}"
}

@test "codebase prompt separates repo-content claims from runtime-behavior claims" {
  # The distinction is the substance of the fix: Read/Grep/Glob settle what a
  # file contains, and settle nothing about how a tool behaves.
  grep -q 'KIND A' "${RUN_REVIEW}"
  grep -q 'KIND B' "${RUN_REVIEW}"
}

@test "pre-merge prompt tells the reviewer to attribute rather than assert" {
  grep -q 'YOU HAVE NO TOOLS' "${PRE_MERGE}"
  grep -q 'attribute it rather than restating it' "${PRE_MERGE}"
}

@test "pre-merge prompt no longer tells the reviewer to run a command" {
  ! grep -q 'run the command that checks it' "${PRE_MERGE}"
  ! grep -q 'Run the one-liner' "${PRE_MERGE}"
}

@test "the unverified-label machinery is still referenced by the codebase prompt" {
  # The prompt change narrows what may be asserted; it must not orphan the
  # existing labelling path in lib-review-issues.sh.
  grep -q 'unverified' "${RUN_REVIEW}"
  grep -q 'warning banner' "${RUN_REVIEW}"
}

@test "codebase prompt separates timing from severity" {
  # The classification used to ask only WHEN a problem originated (introduced
  # vs pre-existing), with no severity axis at all. A reviewer that noticed
  # anything true-but-harmless therefore had exactly one channel for it --
  # NON_BLOCKING_ISSUE -- and every emitted block becomes a GitHub issue,
  # since lib-review-issues.sh gates only on dedup. Issue #429 follow-up.
  grep -q "two INDEPENDENT questions" "${RUN_REVIEW}"
  grep -q "IS IT A DEFECT" "${RUN_REVIEW}"
}

@test "codebase prompt requires a defect before anything is reported" {
  grep -q "Only a defect can be reported at all" "${RUN_REVIEW}"
  grep -q "REPORT NOTHING ELSE" "${RUN_REVIEW}"
}

@test "codebase prompt names the hedging phrases that signal a non-defect" {
  # These are the exact lead-ins that preceded the filed non-defects.
  grep -q "worth noting" "${RUN_REVIEW}"
  grep -q "no code change" "${RUN_REVIEW}"
  grep -q "for the next person" "${RUN_REVIEW}"
}

@test "codebase prompt tells the reviewer to drop findings it resolved itself" {
  # A third of the non-defects conceded they were fine in their own text and
  # were filed regardless.
  grep -q "ends in" "${RUN_REVIEW}"
  grep -q "Do not file the reasoning" "${RUN_REVIEW}"
}

@test "the review cache key includes the script hash" {
  # The filing bar lives in prompt text inside this script, so a prompt edit
  # MUST invalidate cached PASS verdicts. Without SCRIPT_SHA in the key, a
  # tightened prompt would read an old PASS for an identical diff and never
  # run. Observed during validation: a stale entry made a deliberately buggy
  # fixture report PASS, which read as the new prompt suppressing real
  # findings until the cache was cleared and it correctly blocked.
  grep -q 'SCRIPT_SHA=$(shasum' "${RUN_REVIEW}"
  grep -q 'DIFF_HASH=$(printf .*SCRIPT_SHA' "${RUN_REVIEW}"
}

@test "codebase prompt states that filing nothing is a success" {
  # Without this the reviewer reads an empty list as an incomplete job.
  grep -q "Filing nothing is a good outcome" "${RUN_REVIEW}"
  grep -q "successful review, not a lazy one" "${RUN_REVIEW}"
}

@test "pre-merge prompt keeps its relay-only constraint" {
  # This reviewer is NOT the noise source: it may only pass along concerns a
  # human reviewer raised, and already has an explicit omit clause. Pinned so
  # a future edit does not hand it the freedom to originate findings.
  grep -q "Only include concerns that were explicitly mentioned by a reviewer" "${PRE_MERGE}"
  grep -q "Omit this section entirely if there is nothing worth tracking" "${PRE_MERGE}"
}

@test "both prompts still carry the motivating counterexamples" {
  # The concrete false-claim examples are load-bearing: they name the shape of
  # claim that keeps recurring. Losing them would leave an abstract rule.
  grep -q 'grep -w' "${RUN_REVIEW}"
  grep -q 'grep -w' "${PRE_MERGE}"
}
