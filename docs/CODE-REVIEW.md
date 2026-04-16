# Code Review Standards — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - During Protocol 4 AI review iterations
> - When reviewing code (yours or others')
> - When using code-reviewer or adversarial-reviewer agents

---

## General Code Review Checklist

### Security

- [ ] No hardcoded credentials or API keys
- [ ] Input validation on user data
- [ ] No injection vulnerabilities (SQL, XSS, command injection)
- [ ] Proper authentication/authorization checks
- [ ] No sensitive data in logs or error messages
- [ ] Environment variables used for all secrets

### Correctness

- [ ] Logic handles edge cases
- [ ] Async/await used correctly (no missing awaits)
- [ ] Error handling with try-catch or equivalent
- [ ] No race conditions
- [ ] Resource cleanup (connections, listeners, timers, subscriptions)
- [ ] Graceful degradation on external service failures

### Quality

- [ ] Follows existing codebase patterns
- [ ] Self-documenting variable and function names
- [ ] No dead code (remove, don't comment out)
- [ ] DRY — no unnecessary duplication
- [ ] Appropriate level of abstraction
- [ ] **Diagnostic granularity**: distinct failure modes produce distinct error messages (missing dependency ≠ missing file ≠ parse error ≠ value mismatch). Don't let `|| true` or empty-default fallbacks collapse several failure modes into one misleading message. See §Recurring CI Findings for the example-driven rule.

---

## Red Flags — Immediate Rejection

1. Hardcoded credentials or API keys
2. `console.log` or debug statements in production code
3. Commented-out code blocks
4. TODO without GitHub issue reference
5. Disabled linting/type checking rules without justification
6. Missing error handling on async operations
7. Unsanitized user input
8. Synchronous blocking operations in async contexts
9. Tests removed or disabled
10. Coverage decreased without explicit justification

---

## Anti-Patterns to Avoid

- **Over-engineering**: Don't add abstraction until needed (need 3 real examples)
- **Premature optimization**: Profile before optimizing
- **Shotgun surgery**: Changes should be cohesive, not scattered
- **God objects**: Keep components/functions focused
- **Magic numbers**: Use named constants
- **Deep nesting**: Refactor deeply nested conditionals (early returns)
- **Tight coupling**: Components should be loosely coupled
- **Ignoring errors**: Always handle error cases explicitly
- **Skipping review**: Never bypass Protocol 4

---

## When Reviews Find Issues — Rework, Don't Override

When a pre-commit hook or review agent flags an issue, the **strongly preferred** response is to go back and rework the code until it passes cleanly. Do not ask the human to bypass hooks with `--no-verify` or similar overrides.

**Escalation ladder:**

1. **Rework the code** — Fix the flagged issue directly. This is the expected outcome ~90% of the time.
2. **Rework differently** — If the first fix introduced new issues, try a different approach to the original change.
3. **Narrow the commit** — Split the change so the problematic part is isolated and the rest can land cleanly.
4. **After 3+ genuine rework attempts**, if the review agent is flagging something you believe is a false positive or an irreconcilable style disagreement, _then_ explain the situation to the human and ask whether they'd like to override. Present the specific findings and why you believe they're incorrect.

**Never** jump straight to requesting `--no-verify`. The human should only need to override hooks in rare, genuinely exceptional cases — not as a routine escape hatch for review friction.

---

## Recurring CI Findings Signal Local Review Gaps

Local review (pre-commit code-reviewer + adversarial-reviewer, pre-push codebase-reviewer) exists to catch issues **before** push. Every finding that slips to CI costs real time and money; local verification is free.

**The rule:** If CI consistently returns findings local review missed, treat it as a local-review failure — not as CI "catching extra stuff."

**Feedback loop:** When a CI finding lands that local review should have caught, note the category. After 2–3 repeats of the same category, update local reviewer prompts, pre-commit hooks, or this file's checklists so the class of issue is caught locally.

**Not normal workflow:** `post-push-loop` iterations are a safety net, not the primary review mechanism. A PR needing 3+ loop iterations means local review needs improvement.

### Logged patterns

These classes of finding have recurred enough that local review must catch them before push.

**Error-path diagnostic granularity** (logged 2026-04-16 after PR #15, scripts repo, took 5 push cycles)

Every distinct failure mode in a script must produce a distinct, actionable error message. Fallbacks like `$(cmd || true)` or `jq '.x // empty'` merge "dependency missing", "file missing", "parse failed", and "value wrong" into one generic message, forcing the operator to guess which one actually happened.

Checks to apply during pre-commit review of any script:

1. For every `[[ -z "${var}" ]]` check: is there a distinct branch for each way `var` could end up empty (command missing, command ran but no data, data exists but is empty)?
2. For every `cmd || true` / `cmd || :` / `jq '.x // empty'`: is a genuine parse/tool failure swallowed and redirected into a downstream check that names something else?
3. For every external tool invocation (`jq`, `awk`, `curl`, `gh`, ...) used beyond a single one-liner: is there a `command -v <tool>` preflight with a `brew install <tool>` hint?
4. For every file read (`cat`, `jq <file>`, `source <file>`): is there a `[[ -f "${file}" ]]` preflight with a remediation message before the parser runs?

If any of these are missing, flag as BLOCKING in local review — not as a non-blocking observation. The CI reviewer has repeatedly treated these as non-blocking, then flagged the next one after the first was fixed. Treating them as blocking locally breaks that cycle.

---

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
