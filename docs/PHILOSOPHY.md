# Development Philosophy — Andrew Rich

> **Note:** This is auxiliary documentation for `~/.claude/CLAUDE.md`
>
> **When to read:**
>
> - At project start to understand decision frameworks
> - When facing architectural choices or design decisions
> - When unclear about directive compliance levels (Red/Yellow/Green)
> - When onboarding to understand the overall approach
> - When you need to understand "why" behind the protocols

## HOW TO READ THIS DOCUMENT

### Directive Hierarchy

The main CLAUDE.md contains three types of instructions with different compliance requirements:

#### 🔴 MANDATORY PROTOCOLS (Must Follow)

Sections marked "PROTOCOL" or "NON-NEGOTIABLE" are **absolute requirements**.

- **Violation = Session Failure**: If violated, the session has failed
- **No Flexibility**: These are not subject to interpretation or context
- **Automated Enforcement**: Git hooks enforce many of these automatically
- **Andrew's Override Required**: Only Andrew can grant exceptions

**How to recognize**: Sections titled "Protocol N" or marked "MANDATORY"

#### 🟡 STRONG GUIDELINES (Should Follow Unless Justified)

Sections marked "Standards" or "Guidelines" are **default approaches**.

- **Deviation Requires Justification**: Must explain why deviating
- **Context Matters**: Project specifics may warrant different approaches
- **Andrew's Judgment**: Andrew decides if justification is sufficient

**How to recognize**: Sections like "Technical Standards", "Code Review Standards"

#### 🟢 PHILOSOPHY (Informing Principles)

Sections marked "Philosophy" or "Beliefs" are **guiding principles**.

- **Flexible Application**: How to think, not rigid rules
- **Judgment Calls**: Used to make decisions in ambiguous situations
- **Not Checklistable**: Can't be reduced to yes/no compliance

**How to recognize**: "Philosophy", "Core Beliefs", "Epistemic Discipline"

### Interpretation Rules

1. **When in doubt, ask**: If a protocol seems ambiguous, ask Andrew for clarification
2. **Explicit beats implicit**: Direct instructions override inferred intent
3. **Stricter beats looser**: If two rules conflict, follow the stricter one
4. **Context doesn't excuse protocols**: MANDATORY protocols apply regardless of circumstances
5. **Document deviations**: If deviating from guidelines, note it explicitly

### Self-Checking Requirement

At key moments (session start, before commits, before declaring "done"), I MUST:

1. State which protocols apply to current action
2. Confirm I'm following them
3. Flag any deviations with justification

**This is not optional.** Making protocol adherence explicit is itself a protocol.

---

## Philosophy

### Core Beliefs

- **Incremental progress over big bangs** — Small changes that compile and pass tests
- **Learning before implementing** — Study existing code, plan, then build
- **Pragmatic over dogmatic** — Adapt to project reality
- **Clear intent over clever code** — Be boring and obvious; if you need to explain it, it's too complex

### Epistemic Discipline

- **Predictions pay rent** — Before risky actions, state what you expect. After, compare to reality.
- **Notice confusion** — Surprise means your model is wrong. Stop and identify how before continuing.
- **"Should work" is a warning** — When reality contradicts your model, debug the model, not reality.
- **"I don't know" is valid** — State uncertainty explicitly rather than confabulating confidence.

### Simplicity

- Single responsibility per function/class
- Avoid premature abstractions (need 3 real examples before extracting)
- No clever tricks—choose the boring solution

### Chesterton's Fence

Before removing or changing anything, articulate why it exists. Can't explain it? You don't understand it well enough to touch it.

---

## Application Guidelines

### When to Consult This Document

**During Decision-Making:**

- Choosing between multiple valid approaches
- Facing architectural trade-offs
- Unclear whether a guideline applies

**During Conflicts:**

- When protocols seem to conflict
- When context suggests deviating from guidelines
- When interpreting ambiguous instructions

**During Onboarding:**

- Starting work on a new project
- Learning the development philosophy
- Understanding why protocols exist

### How to Apply Philosophy

Philosophy informs judgment but doesn't prescribe action. Use it to:

1. **Guide decisions** in ambiguous situations
2. **Evaluate trade-offs** between competing approaches
3. **Understand intent** behind specific protocols
4. **Make consistent choices** across different contexts

### Philosophy vs. Protocols

- **Protocols** tell you what to do
- **Philosophy** tells you how to think

When protocols are clear, follow them. When protocols are ambiguous or silent, apply philosophy.

---

## Return to Main Documentation

For mandatory protocols and practical standards:
→ Return to `~/.claude/CLAUDE.md`

For command references and templates:
→ See `~/.claude/docs/REFERENCE.md`
