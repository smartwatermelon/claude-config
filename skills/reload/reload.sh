#!/usr/bin/env bash
# The /reload skill injects this. Exits 0 with errors on stdout: a failing
# injected command aborts the skill.

if [[ -z "${CLAUDE_WRAPPER_RELOAD_CMD:-}" ]]; then
  echo "RELOAD UNAVAILABLE: this session was not started by claude-wrapper with reload enabled (launched outside the wrapper, or with -w/--worktree, --tmux, --teleport, --cloud, --bg, or --desktop). Exit and relaunch claude manually."
  exit 0
fi

if ! "${CLAUDE_WRAPPER_RELOAD_CMD}" 2>&1; then
  echo "RELOAD FAILED: the session was not restarted."
fi
exit 0
