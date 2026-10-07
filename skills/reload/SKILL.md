---
name: reload
description: Restart this Claude Code session in place and resume the same conversation, so changes that load only at startup take effect — hooks, skills, settings.json, MCP servers, plugins, CLAUDE.md. Use when the user says "reload" or "restart Claude", or when you changed one of those files and need the new version active to continue. Never run it again right after a reload.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/reload.sh)
---

# Reload

!`bash ${CLAUDE_SKILL_DIR}/reload.sh`

The line above ran when this skill loaded. Report its result to the user in one line:

- "Restarting Claude Code": the restart is in progress. The session ends now and resumes by itself. Do nothing else.
- "RELOAD UNAVAILABLE" or "RELOAD FAILED": the session did not restart. Tell the user why, and tell them to exit and relaunch `claude` themselves.
