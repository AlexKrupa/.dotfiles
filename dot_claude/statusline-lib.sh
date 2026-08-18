# Colors and formatting shared by statusline-command.sh and
# subagent-statusline.sh. Keeps the two lines visually identical.

# Context-window % color (>= value wins; below yellow -> green).
CTX_RED_AT=50
CTX_YELLOW_AT=25

# Colors (actual ESC chars so they embed directly in strings).
# Dracula palette -> truecolor, no bold (Claude Code statusline over-brightens
# bold; plain matches the live starship prompt visually).
C_PATH=$'\033[38;2;139;233;253m'    # #8be9fd, starship directory
C_GIT=$'\033[38;2;189;147;249m'     # #bd93f9, starship git_branch
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_GREEN=$'\033[32m'
C_DIM=$'\033[2m'
C_RESET=$'\033[0m'

sep="${C_DIM}·${C_RESET}"

# Format token count: 1000000 -> 1M, 48000 -> 48k.
fmt_tokens() {
  if [ -z "$1" ] || [ "$1" = "null" ]; then echo "?";
  elif [ "$1" -ge 1000000 ]; then echo "$(( ($1 + 500000) / 1000000 ))M";
  else echo "$(( ($1 + 500) / 1000 ))k"; fi
}

# Color for context %.
pct_color() {
  if [ -z "$1" ]; then printf '%s' "$C_DIM"; return; fi
  local v="${1%.*}"
  if [ "$v" -ge "$CTX_RED_AT" ]; then printf '%s' "$C_RED";
  elif [ "$v" -ge "$CTX_YELLOW_AT" ]; then printf '%s' "$C_YELLOW";
  else printf '%s' "$C_GREEN"; fi
}
