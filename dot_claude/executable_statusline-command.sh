#!/bin/bash

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir')
cwd="${cwd/#$HOME/\~}"
model=$(echo "$input" | jq -r '.model.display_name')

# Shorten path: first letter of each component except last
IFS="/" read -ra parts <<< "$cwd"
len=${#parts[@]}
if [ $len -gt 1 ]; then
  short=""
  for ((i = 0; i < len - 1; i++)); do
    if [ -n "${parts[$i]}" ]; then
      seg="${parts[$i]}"
      [[ "$seg" =~ ^([^[:alnum:]]*[[:alnum:]])(.*)$ ]] && seg="${BASH_REMATCH[1]}"
      short="$short/$seg"
    fi
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

m=$(echo "$model" | sed 's/Claude //' | sed 's/ Sonnet//')

# Extract context window fields
pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
win_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')

# Format window size: 1000000 -> 1M, otherwise Nk
fmt_win() {
  if [ -z "$1" ]; then echo "?";
  elif [ "$1" -ge 1000000 ]; then echo "$(( $1 / 1000000 ))M";
  else echo "$(( $1 / 1000 ))k"; fi
}

# Traffic light color for context percentage
pct_color() {
  if [ -z "$1" ]; then printf '\033[2m';
  else
    local v="${1%.*}"
    if [ "$v" -gt 80 ]; then printf '\033[31m';
    elif [ "$v" -ge 50 ]; then printf '\033[33m';
    else printf '\033[32m'; fi
  fi
}

# Line 1 (optional): vim mode
if [ -n "$vim_mode" ]; then
  upper_mode=$(echo "$vim_mode" | tr '[:lower:]' '[:upper:]')
  if [ "$upper_mode" = "INSERT" ]; then
    printf '\033[33m-- %s --\033[0m\n' "$upper_mode"
  else
    printf '\033[32m-- %s --\033[0m\n' "$upper_mode"
  fi
fi

# Line 2: path, git
printf "\033[36m%s\033[0m%s\n" "$short" "$git_info"

# Line 3: Model | PCT% WINk | $COST
pct_display="${pct:-?}"
[ "$pct_display" != "?" ] && pct_display="${pct_display%.*}"
win_display=$(fmt_win "$win_size")

printf "%s \033[2m|\033[0m $(pct_color "$pct")%s%%\033[0m %s \033[2m| \$%s\033[0m" \
  "$m" \
  "$pct_display" \
  "$win_display" \
  "$([ -n "$cost" ] && printf '%.2f' "$cost" || echo '?')"
