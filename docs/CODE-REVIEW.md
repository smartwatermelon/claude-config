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

## Return to Main Documentation

→ Return to `~/.claude/CLAUDE.md`
