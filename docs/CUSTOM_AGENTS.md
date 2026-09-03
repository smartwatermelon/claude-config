# Custom Agents

This document explains how to manage custom agents that are not part of external packages.

> **Note for Repository Clones:** This configuration is personal. The `~/.claude/agents-local/` directory is not included in this repository (it's `.gitignored`). If you clone this repo, you'll need to create your own `agents-local` directory following the setup instructions below. The git hooks will gracefully skip adversarial-reviewer if it's not present.

## Problem

Custom agents stored in the wshobson/agents marketplace (now forked as smartwatermelon/claude-code-workflows-agents) (`~/.claude/agents/plugins/`) get overwritten when the package updates, because they're treated as part of that package.

## Solution

Custom agents are now stored in a separate local marketplace: `~/.claude/agents-local/`

This directory:

- Is a separate git repository (not a submodule)
- Is excluded from the main `.claude` repository via `.gitignore`
- Won't be touched by package updates
- Can be managed independently and backed up to its own remote

## Directory Structure

```
~/.claude/agents-local/
├── README.md
└── plugins/
    └── adversarial-review/
        └── agents/
            └── adversarial-reviewer.md
```

## How Custom Agents Work

**Important:** You don't need to "install" custom agents. They work automatically once placed in the marketplace directory.

Claude Code discovers agents by scanning marketplace directories (`~/.claude/plugins/marketplaces/`) for `.md` files. A symlink at `~/.claude/plugins/marketplaces/custom-agents` points to `~/.claude/agents-local/`, making all agents in that directory discoverable.

**Usage:**

- **Git hooks**: Invoke via `claude --agent adversarial-reviewer` (works immediately)
- **Task tool**: Use `subagent_type: "code-critic:adversarial-reviewer"` in Task calls (requires full `plugin:agent` format)
- **No restart needed**: Changes to agent files are picked up on next invocation

## Initial Setup

If you're setting up custom agents for the first time (or cloned this repo), follow these steps:

### 1. Create the agents-local directory structure

```bash
mkdir -p ~/.claude/agents-local/plugins/adversarial-review/agents
cd ~/.claude/agents-local
git init
```

### 2. Create the adversarial-reviewer agent

```bash
cat > ~/.claude/agents-local/plugins/adversarial-review/agents/adversarial-reviewer.md << 'EOF'
---
name: adversarial-reviewer
description: Skeptical senior engineer who assumes code is wrong until proven otherwise
model: sonnet
---

# Adversarial Code Reviewer

[Your custom agent prompt here - see existing agent for full content]
EOF
```

### 3. Initialize the git repository

```bash
cd ~/.claude/agents-local
git add .
git commit -m "feat(agents): initial custom agents setup"
```

### 4. Verify the symlink exists

The symlink should already exist from this repo:

```bash
ls -la ~/.claude/plugins/marketplaces/custom-agents
# Should show: custom-agents -> ../../agents-local
```

If the symlink doesn't exist, create it:

```bash
cd ~/.claude/plugins/marketplaces
ln -s ../../agents-local custom-agents
```

### 5. Test the agent

```bash
claude --agent adversarial-reviewer -p "Test prompt"
```

The agent should now be available for git hooks and the Task tool.

## Adding New Custom Agents

To add a new custom agent:

1. Create the plugin structure:

```bash
mkdir -p ~/.claude/agents-local/plugins/my-custom-agent/agents
```

2. Create the agent file:

```bash
cat > ~/.claude/agents-local/plugins/my-custom-agent/agents/my-agent.md << 'EOF'
---
name: my-agent
description: What this agent does
model: sonnet  # or opus, haiku
---

# Agent Prompt

Your agent's system prompt here...
EOF
```

3. Commit it:

```bash
cd ~/.claude/agents-local
git checkout -b add-my-agent
git add .
git commit -m "feat(agents): add my-agent"
git checkout main-branch
git merge add-my-agent
```

4. The agent is immediately available (no restart needed)

## Updating Custom Agents

To update an existing custom agent:

1. Edit the agent file:

```bash
vim ~/.claude/agents-local/plugins/adversarial-review/agents/adversarial-reviewer.md
```

2. Commit the changes:

```bash
cd ~/.claude/agents-local
git checkout -b update-adversarial-reviewer
git add .
git commit -m "feat(agents): update adversarial-reviewer - describe changes"
git checkout main-branch
git merge update-adversarial-reviewer
```

3. Changes take effect on next agent invocation (no restart needed)

## Backup

Since this is a git repository, you can back it up to a remote:

```bash
cd ~/.claude/agents-local
git remote add origin <your-private-repo-url>
git push -u origin main-branch
```

## Current Custom Agents

- **adversarial-review/adversarial-reviewer**: Skeptical senior engineer who reviews code assuming it's wrong until proven otherwise

## Subagent Lifetime Budget

A subagent is expected to finish within **5 minutes or 2.3M tokens, whichever
comes first**. An agent that cannot is a signal that the task's scope is too
large: break it into smaller pieces rather than raising the limit.

The token half is enforced by `scripts/hook-budget-guard.sh` on `SubagentStop`
(`BUDGET_SUBAGENT_TOKENS`, default 2300000). Primary agents must not raise it
without affirmative approval from Andrew — it is not a default that can be
waived unilaterally.

### Where 2.3M comes from

Measured across 447 real subagent transcripts (2026-09-02). A well-behaved
agent averages **416,286 tokens/min**; five minutes of that is 2.08M, plus a
10% buffer gives 2.3M. It is the token expression of the five-minute limit,
not an independent number — of the 93 agents this ceiling blocks, 85 (91%)
also ran over five minutes.

For scale: the cheapest of all 447 agents spent **32,996 tokens**. A ceiling
in the tens of thousands sits below the observed floor.

### What actually drives the cost

Cost is dominated by `cache_read` — every turn re-reads the whole accumulated
context, so spend tracks `turns x context size`. Continuing is the expense,
not repeating. Two consequences:

- A long agent at high context costs far more than several short ones.
- Trimming what an agent carries pays off on *every* turn, not once.

### Writing a thrifty dispatch prompt

Measured on a real incident: ~33K of a ~40K per-agent entry cost was
self-inflicted by prompt wording, not harness overhead. Subagents start cold,
so none of it is cache-amortized.

- **Hand over interfaces and contracts, not whole files.** The specific
  anti-pattern is "read X in full" for a file the agent will not modify. One
  agent was told to read a 1,685-line test harness (~17K tokens) when it
  needed ~19 function signatures and one sample test (~750 tokens) — a 96%
  reduction on the largest single item.
- **Scope the tools.** Agent frontmatter supports `tools:` / `allowed-tools:` /
  `disallowed-tools:`. Prefer a narrow purpose-built agent over a generic
  `general-purpose` spawn.
- **State the design decision before dispatching a build agent.** The single
  largest line item in the incident was building the wrong thing: 12 requests
  preceded a dispatch that was killed 5 minutes later, discarding 1.63M
  tokens. If the deciding evidence is not already in hand, ask first.

There is **no** flag to suppress `CLAUDE.md` injection —
`skipProjectInstructions` and `systemPromptAppend` return zero hits in the
v2.1.259 binary. Do not hunt for one. The harness baseline (~7.3K) is small;
the prompt is where the savings are.

### Why the cap cannot terminate a running agent

A blocking `SubagentStop` (exit 2) does **not** kill the subagent. Verified in
the v2.1.259 binary: the blocking message is appended to the conversation,
`stop_hook_active` is set, and the turn loop continues — the agent keeps
running with the block as new context. Blocking is itself capped at
`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8), and applies to `Stop` and
`SubagentStop` alike.

So the guard is a post-hoc circuit breaker, not a live cap, and each wasted
block costs a full-context turn. This is why `hook-budget-guard.sh` honors
`stop_hook_active` and exits 0 rather than blocking repeatedly.

The only mechanisms that genuinely bound an agent's lifetime are harness-level:
`CLAUDE_CODE_MAX_TURNS`, `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`,
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION`,
`CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`. For `claude` invoked from a shell (the
review hooks), `timeout` supplies the wall-clock bound — those call sites
already use it, with per-call budgets tuned to prompt size.
