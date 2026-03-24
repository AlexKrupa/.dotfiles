#!/bin/bash

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir')
raw_cwd="$cwd"
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
if git -C "$raw_cwd" rev-parse --git-dir &>/dev/null; then
  br=$(git -C "$raw_cwd" --no-optional-locks branch --show-current 2>/dev/null \
    || git -C "$raw_cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$br" ]; then
    st=""
    git -C "$raw_cwd" --no-optional-locks diff --quiet 2>/dev/null \
      && git -C "$raw_cwd" --no-optional-locks diff --cached --quiet 2>/dev/null \
      || st="*"
    git_info=" on "$'\033[35m'"${br}${st}"$'\033[0m'
  fi
fi

m=$(echo "$model" | sed 's/Claude //' | sed 's/ Sonnet//' | sed 's/ ([^)]*context)//')
model_id=$(echo "$input" | jq -r '.model.model_id // empty')

# Effort level from settings
effort=""
settings="$HOME/.claude/settings.json"
if [ -f "$settings" ]; then
  effort=$(jq -r '.effortLevel // empty' "$settings" 2>/dev/null)
fi
if [ -z "$effort" ]; then
  case "$model_id" in
    *opus-4-6*|*sonnet-4-6*) effort="medium" ;;
    *) effort="high" ;;
  esac
fi
# Append effort suffix (skip for Haiku)
effort_suffix=""
case "$model_id" in
  *haiku*) ;;
  *) effort_suffix=$(echo "${effort:0:1}" | tr '[:lower:]' '[:upper:]') ;;
esac

# Rate limit usage (non-blocking, cache-based)
usage_cache_dir="$HOME/.cache/claude-statusline"
usage_cache="$usage_cache_dir/usage.json"

# Background refresh if cache older than 10 min or missing
need_refresh=0
if [ ! -f "$usage_cache" ]; then
  need_refresh=1
else
  case "$(uname)" in
    Darwin) cache_age=$(( $(date +%s) - $(stat -f %m "$usage_cache") )) ;;
    *) cache_age=$(( $(date +%s) - $(stat -c %Y "$usage_cache") )) ;;
  esac
  [ "$cache_age" -gt 600 ] && need_refresh=1
fi
[ "$need_refresh" -eq 1 ] && bash ~/.claude/refresh-usage.sh &

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

# Traffic light color for utilization percentage (same thresholds as context)
util_color() {
  if [ -z "$1" ]; then return; fi
  local v="${1%.*}"
  if [ "$v" -ge 80 ]; then printf '\033[31m';
  elif [ "$v" -ge 50 ]; then printf '\033[33m';
  else printf '\033[32m'; fi
}

pct_display="${pct:-?}"
[ "$pct_display" != "?" ] && pct_display="${pct_display%.*}"
win_display=$(fmt_win "$win_size")

# Format a usage window: usage_fmt <label> <utilization> <resets_at> <time_fmt>
# Outputs segment string to stdout, empty if no data
usage_fmt() {
  local label="$1" util="$2" resets="$3" tfmt="$4"
  [ -z "$util" ] || [ "$util" = "null" ] && return
  local pct=$(awk "BEGIN { printf \"%.0f\", $util }")
  local seg="${label}:$(util_color "$pct")${pct}%\033[0m"
  if [ "$pct" -ge 50 ] && [ -n "$resets" ]; then
    local ts="${resets%+*}"; ts="${ts%Z}"
    local epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts" "+%s" 2>/dev/null)
    # API returns :00 or :59 inconsistently; round to nearest minute
    [ -n "$epoch" ] && epoch=$(( (epoch + 30) / 60 * 60 ))
    [ -n "$epoch" ] && seg="$seg → $(date -r "$epoch" "+$tfmt")"
  fi
  printf '%s' "$seg"
}

# Build utilization segment
usage_seg=""
if [ -f "$usage_cache" ]; then
  seg_5h=$(usage_fmt "5h" \
    "$(jq -r '.five_hour.utilization // empty' "$usage_cache" 2>/dev/null)" \
    "$(jq -r '.five_hour.resets_at // empty' "$usage_cache" 2>/dev/null)" \
    "%H:%M")
  seg_7d=$(usage_fmt "7d" \
    "$(jq -r '.seven_day.utilization // empty' "$usage_cache" 2>/dev/null)" \
    "$(jq -r '.seven_day.resets_at // empty' "$usage_cache" 2>/dev/null)" \
    "%a %H:%M")
  [ -n "$seg_5h" ] && usage_seg="$seg_5h"
  [ -n "$seg_7d" ] && usage_seg="${usage_seg:+$usage_seg \033[2m|\033[0m }$seg_7d"
fi

# Line 3: Model E | PCT% WINk | $COST [| 5h:N% | 7d:N%]
printf "%s%s \033[2m|\033[0m $(pct_color "$pct")%s%%\033[0m %s \033[2m| \$%s\033[0m" \
  "$m" "${effort_suffix:+ $effort_suffix}" "$pct_display" "$win_display" \
  "$([ -n "$cost" ] && printf '%.2f' "$cost" || echo '?')"
[ -n "$usage_seg" ] && printf " \033[2m|\033[0m %b" "$usage_seg"
printf "\n"
