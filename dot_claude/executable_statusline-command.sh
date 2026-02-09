#!/bin/bash

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')

# Shorten path: first letter of each component except last
IFS="/" read -ra parts <<< "$cwd"
len=${#parts[@]}
if [ $len -gt 1 ]; then
  short=""
  for ((i = 0; i < len - 1; i++)); do
    [ -n "${parts[$i]}" ] && short="$short/${parts[$i]:0:1}"
  done
  short="$short/${parts[$len - 1]}"
  short="${short#/}"
else
  short="$(basename "$cwd")"
fi

# Git branch + dirty indicator
git_info=""
if git -C "$cwd" rev-parse --git-dir &>/dev/null; then
  br=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null \
    || git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$br" ]; then
    st=""
    git -C "$cwd" --no-optional-locks diff --quiet 2>/dev/null \
      && git -C "$cwd" --no-optional-locks diff --cached --quiet 2>/dev/null \
      || st="*"
    git_info=" on "$'\033[35m'"${br}${st}"$'\033[0m'
  fi
fi

t=$(date +%H:%M:%S)
m=$(echo "$model" | sed 's/Claude //' | sed 's/ Sonnet//')

printf "\033[36m%s\033[0m%s \033[2m%s [%s]\033[0m" "$short" "$git_info" "$t" "$m"

