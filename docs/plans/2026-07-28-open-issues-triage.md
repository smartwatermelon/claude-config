# Open Issues Triage & Execution Plan

**Goal:** Work through all 42 open GitHub issues in `smartwatermelon/claude-config` — fix what's still valid, close what's already fixed/obsolete, defer what's low-value, and record why for each.

**Method:** Every issue was checked against the *current* state of the code (not just re-read), since many are old (Apr–May 2026) and the review-hook infrastructure (`hooks/run-review.sh`, `hooks/lib-review-issues.sh`) has changed substantially since (`#174` REVISE-normalization, `#197` markdown-VERDICT tolerance, `#195` issue-filing rework, `#204` settings cleanup).

---

## Priority 1 — Fix now (correctness/safety in the review gate itself)

These touch `hooks/run-review.sh`, the mechanism that gates every commit/push in this and other repos. Bugs here are highest-leverage.

| # | Title | Fix |
|---|---|---|
| **200** | Chunked review exits 0 when 0/N files reviewed (fail-open) | Add guard: if `file_count > 0 && reviewed_files == 0`, treat as FAIL, not silent pass. `hooks/run-review.sh:609-620` |
| **199** | Adversarial reviewer blocks on warnings-only FAIL; code-reviewer doesn't (severity asymmetry) | Add the same `grep -q "SEVERITY: BLOCKING"` gate to the adversarial branch that code-reviewer already has. `hooks/run-review.sh:1209-1231` |
| **166** | SIGPIPE on large DIFF can misreport pipeline exit status under `pipefail`, silently skipping review | Replace `echo "${DIFF}" \| grep -qE ...` with a temp-file or here-string form that can't race. `hooks/run-review.sh:740` |
| **171** | `2>/dev/null` on `echo` is a no-op, misleading | Remove it as part of the #166 fix (same line). |
| **148** | `grep -v '^#' \| awk` can trip `set -e`/pipefail on empty/template-only commit message | Add `\|\| true` guard at both call sites. `hooks/run-review.sh:315,337` |
| **90** | No trap cleanup for `DIFF_TMPFILE` | Add it to the existing EXIT trap alongside `_chunk_results`/`_cr_out`/`_ar_out`. `hooks/run-review.sh:657,911,979` |
| **89** | Codebase mode `2>&1` pollutes verdict parsing | Separate stdout/stderr capture. `hooks/run-review.sh:972` |

## Priority 2 — Fix now (guard/safety gaps outside the review engine)

| # | Title | Fix |
|---|---|---|
| **114** | `merge-lock` accepts `pr-0` as a valid PR number | Add `-gt 0` to the numeric guard. `hooks/merge-lock.sh:~132` |
| **137** | Newline-chained `gh api .../merge` bypasses the API-merge guard after `^\|` removal | Extend the blocked-pattern regex to catch a `gh api ... merge` on its own line, not just after a shell metachar. `scripts/hook-block-api-merge.sh:42` |
| **180** | `gh issue create` fires even when the target repo has Issues disabled → 30 stderr warnings/push | Guard with `gh api repos/{owner}/{repo} --jq .has_issues` before creating. `hooks/lib-review-issues.sh:421` |

## Priority 3 — Fix now (test coverage & logging gaps)

| # | Title | Fix |
|---|---|---|
| **173** | "Revise" paths in chunked/full-diff/codebase modes have no dedicated test coverage | Add 3 tests mirroring existing Test 11, one per mode. `hooks/tests/run-review-test.sh` |
| **160** | No test coverage for `review.model` / `MODEL_ARGS` override | Add a test exercising `git config review.model`. `hooks/tests/run-review-test.sh` |
| **159** | Model selection not logged in full-diff/codebase modes | Log the resolved model before those modes' early exits. `hooks/run-review.sh` |
| **98** | Missing indentation inside `install.sh` else block | Cosmetic; fix while touching nearby code. `install.sh:386-387` |

## Priority 4 — Fix now (docs, all trivial one-liners — batch into one PR)

| # | Title | Fix |
|---|---|---|
| **102** | Cross-reference uses partial section heading | `docs/INFRASTRUCTURE.md:30` |
| **119** | Cross-reference should point to "Logged patterns" subsection | `docs/CODE-REVIEW.md:40` |
| **121** | Tighten PATH-shim wording (`command -v` vs `hash`) | `~/.claude/CLAUDE.md:201` (this file, `~/Developer/claude-config`'s copy) |
| **123** | Document rationale for `useAutoModeDuringPlan=false` | `docs/INFRASTRUCTURE.md` + pointer from `settings.json:133` |
| **143** | Comment references a plan file that doesn't exist | Either write the missing plan or fix the comment. `.github/workflows/dependabot-auto-merge.yml:25` |
| **147** | `_read_commit_message` docs claim full-diff support it doesn't have | Fix the doc comment to match reality (full-diff mode doesn't call it). `hooks/run-review.sh:298` |
| **165** | No documentation of A/B (Sonnet vs Haiku) review semantics | Add a short comment block to the workflow file or `docs/CUSTOM_AGENTS.md`. |

## Priority 5 — Fix now (CI workflow)

| # | Title | Fix |
|---|---|---|
| **162** | Two parallel review jobs share the same PR comment marker (race) | Add `needs: claude-review` to `claude-review-haiku` in `.github/workflows/claude-blocking-review.yml` to serialize them — cheapest fix that stays inside this repo (the marker itself lives in the external reusable workflow). |

---

## Close — already fixed by later work

| # | Title | Why closed |
|---|---|---|
| **101** | Clarify local vs remote branch deletion in Protocol 6 | Already documented (`CLAUDE.md:145,156`). |
| **163** | Model name `claude-haiku-4-5-20251001` unverifiable | Verified current/valid — matches the live Haiku 4.5 model ID. |
| **177** | Pre-push SSH timeouts / 56% push failure rate | Root causes (REVISE parse failures blocking, timeout treated as blocking in push mode) fixed by #174 and the SEVERITY:BLOCKING gating now shared across all modes. Residual SIGPIPE component tracked separately as **#166** (Priority 1 above). |
| **178** | Adversarial reviewer parse failures / chronic timeouts / false positives | Item 1 (REVISE parse failure) fixed by #174 (`17922e5`). Item 2 (timeout blocking in push mode) already non-blocking via the shared `SEVERITY: BLOCKING` check in full-diff/codebase modes — verified in current code. Item 3 (false positives) has no reproducible signal to act on. |
| **179** | Code reviewer treats markdown as code, blocks doc-only commits | Fixed: markdown-only-diff skip now exists (`hooks/run-review.sh:779-785`, "Skip code review for markdown files"). |
| **100** | Clarify `POSTPUSH_LOOP=1` scope | Obsolete — `POSTPUSH_LOOP` no longer appears anywhere in the repo; the mechanism it referred to was removed/renamed. |
| **95** | Seer check still in progress at merge time (PR #93) | One-off historical timing note about a specific past PR, not a recurring defect. |

## Defer — real but low-value or hypothetical; revisit if they actually bite

| # | Title | Why deferred |
|---|---|---|
| **91** | `install.sh` unguarded empty-array iteration | Theoretical only — this repo always has submodules. |
| **92** | `update-tools.sh` submodule check always succeeds | Dead-code assertion, harmless given repo always has submodules. |
| **104** | Align "override" vs "bypass" terminology | Polish, not incoherent as-is. |
| **115** | `merge-lock` batch-auth uses unscoped case-block vars | Script is never sourced today; risk is hypothetical. |
| **116** | Test teardown doesn't guard `TMP_HOME` reassignment | No current test reassigns HOME mid-test; no active bug. |
| **157** | Mixed SSH/HTTPS submodule URLs in `.gitmodules` | Real friction only on a fresh clone without SSH keys configured; low frequency. |
| **168** | `review-cache` in `_KNOWN_RUNTIME` with no confirmed creator | Allowlist is for the general `~/.claude` runtime tree (app-managed), not just this repo's own scripts — plausibly anticipatory, cosmetic either way. |
| **169** | `policy-limits.json` in `_KNOWN_RUNTIME` with no confirmed creator | Same as #168. |
| **172** | Adversarial transient-bypass doesn't cover a hypothetical `VERDICT: Revise (timeout...)` form | No code path currently emits that form; revisit if synthetic transient strings ever change. |
| **175** | Submodule content delta not reviewable from parent-repo diff alone | Inherent limitation of diff-based review, not a bug; the issue's own suggested mitigation (manual `git log` check before push) is a habit, not code. |
| **34** | Continuous Improvement System: Automated CLAUDE.md Evolution | The now-live auto-memory system (`~/.claude/projects/.../memory/`) already covers the core goal — capturing corrective feedback so it isn't repeated — at far lower cost than the proposed 10-week hook/cron/DB build. Recommend closing as superseded; reopen only if memory usage data later shows it's not catching recurring corrections. |

---

## Suggested execution order

Per standing instructions, each batch below is one subagent-driven PR (branch → implement → test → local review → push → CI → merge-lock authorization).

1. **PR 1 — Review-engine safety** (#200, #199, #166, #171, #148, #90, #89) — highest leverage, touches the gate everything else depends on.
2. **PR 2 — Guard gaps** (#114, #137, #180)
3. **PR 3 — Test coverage & logging** (#173, #160, #159, #98)
4. **PR 4 — Docs cleanup** (#102, #119, #121, #123, #143, #147, #165) — one PR, all trivial.
5. **PR 5 — CI workflow serialization** (#162)
6. **Close pass** — close #101, #163, #177, #178, #179, #100, #95 with the reasoning above as the closing comment.
7. **Defer pass** — leave #91, #92, #104, #115, #116, #157, #168, #169, #172, #175, #34 open but label/comment with the deferral reasoning so future triage doesn't re-derive it from scratch.

Total: 24 fix, 7 close, 11 defer (42 issues).
