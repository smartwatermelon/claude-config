#!/usr/bin/env bash
# StatusLine: Display git branch and status in prompt

input=$(cat)
current_dir=$(echo "$input" | jq -r '.workspace.current_dir')

cd "${current_dir}" 2>/dev/null || true

git_branch=$(git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/')
git_status=$(git status --porcelain 2>/dev/null)

indicators=""
if echo "${git_status}" | grep -q "^ M"; then
  indicators+="*"
fi
if echo "${git_status}" | grep -q "^M"; then
  indicators+="+"
fi
if echo "${git_status}" | grep -q "??"; then
  indicators+="?"
fi

if [[ -n "${indicators}" ]]; then
  git_status=" [${indicators}]"
else
  git_status=""
fi

printf "\033[32m%s@%s\033[0m:\033[34m%s\033[31m%s%s\033[0m" \
  "$(whoami)" \
  "$(hostname -s)" \
  "${current_dir/#$HOME/~}" \
  "${git_branch}" \
  "${git_status}"
