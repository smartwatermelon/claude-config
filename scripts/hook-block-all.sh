#!/usr/bin/env bash
# Hook: Wrapper that runs all block hooks
# Keeps settings.json clean by consolidating block checks

set -euo pipefail
unset CDPATH

# The hooks below use bash 4+ builtins (mapfile, ${var,,}). `env bash` gives
# whatever bash is first on the PATH Claude Code was launched with, and without
# Homebrew on that PATH it is macOS /bin/bash 3.2: hook-block-git-worktree.sh
# then dies on `mapfile` with exit 127, and every command runs unchecked.
# Re-exec under a newer bash, and put its directory first on PATH so each
# child hook's `env bash` resolves to it too. The Homebrew keg directories come
# first because they hold only bash, so the PATH change cannot also change
# which python3 or gh a hook finds. This must run before stdin is read: exec
# hands the same stdin to the new process.
if ((BASH_VERSINFO[0] < 4)); then
  for candidate in /opt/homebrew/opt/bash/bin/bash /usr/local/opt/bash/bin/bash \
    /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "${candidate}" ]]; then
      PATH="${candidate%/*}:${PATH}" exec "${candidate}" "$0" "$@"
    fi
  done
  printf 'hook-block-all.sh: bash %s is too old and no bash 4+ was found; block hooks did not run\n' "${BASH_VERSION}" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read input once and pass to each hook
input=$(cat)

# Every hook below is REQUIRED. hook-block-secret-leak.sh runs FIRST,
# deliberately. Every other hook here logs the full command text to
# blocked-commands.log when it blocks, and this loop stops at the first hook
# that does. If a command carries a live secret AND trips another rule, running
# that other hook first would write the secret to disk before the secret-leak
# hook ever saw it. First position means the name-only log wins.
REQUIRED_HOOKS=(
  hook-block-secret-leak.sh
  hook-block-gate-dir-write.sh
  hook-block-no-verify.sh
  hook-block-short-no-verify.sh
  hook-block-main-commit.sh
  hook-block-personify.sh
  hook-check-commit-message.py
  hook-block-merge-lock-authorize.sh
  hook-block-api-merge.sh
  hook-block-git-worktree.sh
)

# Fail closed (#660). This loop used to skip a hook that was not executable, so
# a lost symlink disabled that guard without a word. Check the whole list before
# running any hook, and block with exit 2 (the PreToolUse block code) if one is
# missing, dangling or not executable. This blocks every Bash call, including
# the fix, so the message tells the human to run it in a terminal.
missing=()
for name in "${REQUIRED_HOOKS[@]}"; do
  hook="${SCRIPT_DIR}/${name}"
  if [[ -L "${hook}" && ! -e "${hook}" ]]; then
    missing+=("${hook} (dangling symlink)")
  elif [[ ! -e "${hook}" ]]; then
    missing+=("${hook} (missing)")
  elif [[ ! -x "${hook}" ]]; then
    missing+=("${hook} (not executable)")
  fi
done
if ((${#missing[@]} > 0)); then
  printf 'hook-block-all.sh: BLOCKED: required hook(s) cannot run, so no Bash command is checked:\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  printf 'Fix (in a terminal; Bash tool calls stay blocked until then): run install.sh --sync from the claude-config clone.\n' >&2
  printf 'If a hook is "not executable", chmod +x it in the repo and commit.\n' >&2
  exit 2
fi

for name in "${REQUIRED_HOOKS[@]}"; do
  printf '%s\n' "${input}" | "${SCRIPT_DIR}/${name}" || exit $?
done
