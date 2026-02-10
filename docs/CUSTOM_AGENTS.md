# Custom Agents

This document explains how to manage custom agents that are not part of external packages.

> **Note for Repository Clones:** This configuration is personal. The `~/.claude/agents-local/` directory is not included in this repository (it's `.gitignored`). If you clone this repo, you'll need to create your own `agents-local` directory following the setup instructions below. The git hooks will gracefully skip adversarial-reviewer if it's not present.

## Problem

Custom agents stored in the wshobson/agents marketplace (`~/.claude/agents/plugins/`) get overwritten when the package updates, because they're treated as part of that package.

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
