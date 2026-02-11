#!/usr/bin/env bash
# Hook: SessionStart - placeholder for project-specific setup
#
# Project-specific setup hooks can be configured in each project's
# .claude/hooks/ directory and invoked via the claude-wrapper's
# pre-launch hook mechanism (see ~/.local/bin/claude-wrapper).

# Consume stdin (required by hook protocol)
cat >/dev/null
