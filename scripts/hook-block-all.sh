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

# hook-block-secret-leak.sh runs FIRST, deliberately. Every other hook here
# logs the full command text to blocked-commands.log when it blocks, and this
# loop stops at the first hook that does. If a command carries a live secret
# AND trips another rule, running that other hook first would write the secret
# to disk before the secret-leak hook ever saw it. First position means the
# name-only log wins.
for hook in \
  "${SCRIPT_DIR}/hook-block-secret-leak.sh" \
  "${SCRIPT_DIR}/hook-block-gate-dir-write.sh" \
  "${SCRIPT_DIR}/hook-block-no-verify.sh" \
  "${SCRIPT_DIR}/hook-block-short-no-verify.sh" \
  "${SCRIPT_DIR}/hook-block-main-commit.sh" \
  "${SCRIPT_DIR}/hook-block-personify.sh" \
  "${SCRIPT_DIR}/hook-check-commit-message.py" \
  "${SCRIPT_DIR}/hook-block-merge-lock-authorize.sh" \
  "${SCRIPT_DIR}/hook-block-api-merge.sh" \
  "${SCRIPT_DIR}/hook-block-git-worktree.sh"; do
  if [[ -x "${hook}" ]]; then
    printf '%s\n' "${input}" | "${hook}" || exit $?
  fi
done
