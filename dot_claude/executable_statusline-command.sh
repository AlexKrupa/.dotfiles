#!/bin/bash
# ============================================================
# Statusline configuration (everything tunable lives here)
# ============================================================

# Line 3 segment order. Reorder or drop keys. Available:
#   model ctx usage cost lines
SEGMENT_ORDER=(model ctx usage)

# Context-window % color (>= value wins; below yellow -> green).
CTX_RED_AT=50
CTX_YELLOW_AT=25

# Rate-limit utilization % color (5h/7d windows).
UTIL_RED_AT=80
UTIL_YELLOW_AT=50

# Show a window's reset time when its utilization % >= this.
USAGE_RESET_AT=50

# Hide usage segment when terminal narrower than this (COLUMNS from Claude Code).
USAGE_MIN_COLUMNS=80

# date(1) format strings for usage reset times.
USAGE_5H_TIMEFMT='%H:%M'
USAGE_7D_TIMEFMT='%a %H:%M'

# Colors (actual ESC chars so they embed directly in strings).
# Starship default named colors (no palette) -> ANSI, bold:
C_CYAN=$'\033[1;36m'      # ANSI cyan, bold: starship directory, no palette
C_MAGENTA=$'\033[1;35m'   # ANSI magenta, bold: starship git_branch, no palette
# Dracula palette equivalents -> truecolor, no bold (Claude Code statusline
# over-brightens bold; plain matches the live starship prompt visually):
C_DRACULA_CYAN=$'\033[38;2;139;233;253m'    # #8be9fd
C_DRACULA_PURPLE=$'\033[38;2;189;147;249m'  # #bd93f9
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_GREEN=$'\033[32m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'
C_VIM_INSERT=$'\033[33m'
C_VIM_NORMAL=$'\033[32m'

# Role -> color delegation (palette=dracula active)
C_PATH="$C_DRACULA_CYAN"    # starship directory
C_GIT="$C_DRACULA_PURPLE"   # starship git_branch

sep="${C_DIM}·${C_RESET}"

# ============================================================
# Helpers
# ============================================================

# Format window size: 1000000 -> 1M, otherwise Nk.
fmt_win() {
  if [ -z "$1" ]; then echo "?";
  elif [ "$1" -ge 1000000 ]; then echo "$(( $1 / 1000000 ))M";
  else echo "$(( $1 / 1000 ))k"; fi
}

# Color for context %.
pct_color() {
  if [ -z "$1" ]; then printf '%s' "$C_DIM"; return; fi
  local v="${1%.*}"
  if [ "$v" -ge "$CTX_RED_AT" ]; then printf '%s' "$C_RED";
  elif [ "$v" -ge "$CTX_YELLOW_AT" ]; then printf '%s' "$C_YELLOW";
  else printf '%s' "$C_GREEN"; fi
}

# Color for utilization %.
util_color() {
  [ -z "$1" ] && return
  local v="${1%.*}"
  if [ "$v" -ge "$UTIL_RED_AT" ]; then printf '%s' "$C_RED";
  elif [ "$v" -ge "$UTIL_YELLOW_AT" ]; then printf '%s' "$C_YELLOW";
  else printf '%s' "$C_GREEN"; fi
}

# Format one usage window: usage_fmt <label> <pct> <resets_epoch> <time_fmt>
usage_fmt() {
  local label="$1" pct="$2" resets="$3" tfmt="$4"
  [ -z "$pct" ] || [ "$pct" = "null" ] && return
  pct=$(printf '%.0f' "$pct")
  local seg="${label}:$(util_color "$pct")${pct}%${C_RESET}"
  if [ "$pct" -ge "$USAGE_RESET_AT" ] && [ -n "$resets" ] && [ "$resets" != "null" ]; then
    local epoch=$(( (resets + 30) / 60 * 60 ))
    seg="$seg → $(date -r "$epoch" "+$tfmt")"
  fi
  printf '%s' "$seg"
}

# ============================================================
# Input
# ============================================================

input=$(cat)

# Single jq pass: emit fields in order, read line by line (values assumed
# newline-free; cwd/branch never contain newlines in practice).
{
  IFS= read -r cwd
  IFS= read -r model
  IFS= read -r model_id
  IFS= read -r pct
  IFS= read -r win_size
  IFS= read -r cost
  IFS= read -r added
  IFS= read -r removed
  IFS= read -r vim_mode
  IFS= read -r u5_pct
  IFS= read -r u5_reset
  IFS= read -r u7_pct
  IFS= read -r u7_reset
} < <(echo "$input" | jq -r '
  .workspace.current_dir,
  .model.display_name,
  (.model.model_id // ""),
  (.context_window.used_percentage // ""),
  (.context_window.context_window_size // ""),
  (.cost.total_cost_usd // ""),
  (.cost.total_lines_added // 0),
  (.cost.total_lines_removed // 0),
  (.vim.mode // ""),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.rate_limits.seven_day.used_percentage // ""),
  (.rate_limits.seven_day.resets_at // "")')

raw_cwd="$cwd"
cwd="${cwd/#$HOME/\~}"

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
    git_info=" on ${C_GIT}${br}${st}${C_RESET}"
  fi
fi

m=$(echo "$model" | sed 's/Claude //; s/ Sonnet//; s/ ([^)]*context)//')

# Effort level: prefer live session value, fall back to settings.json, then EFFORT_DEFAULTS
effort="${CLAUDE_EFFORT:-}"
if [ -z "$effort" ]; then
  settings="$HOME/.claude/settings.json"
  if [ -f "$settings" ]; then
    effort=$(jq -r '.effortLevel // empty' "$settings" 2>/dev/null)
  fi
fi
# Append effort suffix (skip for Haiku; omitted when effort unknown)
effort_suffix=""
case "$model_id" in
  *haiku*) ;;
  *) effort_suffix=$(echo "${effort:0:1}" | tr '[:lower:]' '[:upper:]') ;;
esac

pct_display="${pct:-?}"
[ "$pct_display" != "?" ] && pct_display="${pct_display%.*}"
win_display=$(fmt_win "$win_size")

# Build utilization segment (5h then 7d)
usage_seg=""
seg_5h=$(usage_fmt "5h" "$u5_pct" "$u5_reset" "$USAGE_5H_TIMEFMT")
seg_7d=$(usage_fmt "7d" "$u7_pct" "$u7_reset" "$USAGE_7D_TIMEFMT")
[ -n "$seg_5h" ] && usage_seg="$seg_5h"
[ -n "$seg_7d" ] && usage_seg="${usage_seg:+$usage_seg $sep }$seg_7d"

# ============================================================
# Output
# ============================================================

# Line 1 (optional): vim mode
if [ -n "$vim_mode" ]; then
  upper_mode=$(echo "$vim_mode" | tr '[:lower:]' '[:upper:]')
  [ "$upper_mode" = "INSERT" ] && vc="$C_VIM_INSERT" || vc="$C_VIM_NORMAL"
  printf '%s-- %s --%s\n' "$vc" "$upper_mode" "$C_RESET"
fi

# Line 2: path, git
printf '%s%s%s%s\n' "$C_PATH" "$short" "$C_RESET" "$git_info"

# Line 3 segments. Each seg_<key> is a self-contained ANSI-ready string
# (empty = skipped). Order/visibility controlled by SEGMENT_ORDER in config.
seg_model="${m}${effort_suffix:+ $effort_suffix}"
seg_ctx="$(pct_color "$pct")${pct_display}%${C_RESET} ${win_display}"
seg_usage=""
if [ -n "$usage_seg" ] && { [ -z "$COLUMNS" ] || [ "$COLUMNS" -ge "$USAGE_MIN_COLUMNS" ]; }; then
  seg_usage="$usage_seg"
fi
seg_cost="${C_DIM}\$$([ -n "$cost" ] && printf '%.2f' "$cost" || echo '?')${C_RESET}"
seg_lines=""
if [ "$added" -gt 0 ] || [ "$removed" -gt 0 ]; then
  seg_lines="${C_GREEN}+${added}${C_RESET}/${C_RED}-${removed}${C_RESET}"
fi

line=""
for key in "${SEGMENT_ORDER[@]}"; do
  val="seg_$key"; val="${!val}"
  [ -z "$val" ] && continue
  line="${line:+$line $sep }$val"
done
printf '%s\n' "$line"
