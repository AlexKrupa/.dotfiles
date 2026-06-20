#!/bin/bash

input=$(cat)

now=$(date +%s)

# Format token count: 12000 -> 12k, 1500000 -> 1M
fmt_tokens() {
  local n="$1"
  [ -z "$n" ] || [ "$n" = "null" ] && { echo "0k"; return; }
  if [ "$n" -ge 1000000 ]; then echo "$(( (n + 500000) / 1000000 ))M";
  else echo "$(( (n + 500) / 1000 ))k"; fi
}

# Elapsed since startTime (epoch s or ms) -> "Xm Ys" or "Ys"
fmt_elapsed() {
  local start="$1"
  [ -z "$start" ] || [ "$start" = "null" ] && { echo ""; return; }
  # Normalize ms -> s (13-digit epoch ms is > 1e12)
  if [ "$start" -gt 1000000000000 ]; then start=$(( start / 1000 )); fi
  local d=$(( now - start ))
  [ "$d" -lt 0 ] && d=0
  local m=$(( d / 60 )) s=$(( d % 60 ))
  if [ "$m" -gt 0 ]; then echo "${m}m ${s}s"; else echo "${s}s"; fi
}

echo "$input" | jq -c '.tasks[]?' | while IFS= read -r task; do
  id=$(echo "$task" | jq -r '.id // empty')
  [ -z "$id" ] && continue
  name=$(echo "$task" | jq -r '.name // empty')
  type=$(echo "$task" | jq -r '.type // empty')
  status=$(echo "$task" | jq -r '.status // empty')
  start=$(echo "$task" | jq -r '.startTime // empty')
  tokens=$(echo "$task" | jq -r '.tokenCount // 0')

  case "$status" in
    running)        dot=$'\033[32m●\033[0m' ;;  # green
    completed)      dot=$'\033[2m●\033[0m' ;;   # dim
    error|failed)   dot=$'\033[31m●\033[0m' ;;  # red
    *)              dot=$'\033[2m●\033[0m' ;;   # dim fallback
  esac

  elapsed=$(fmt_elapsed "$start")
  tok=$(fmt_tokens "$tokens")

  # <dot> <name> [<type>] <elapsed> · <tokens>
  content="$dot $name"
  [ -n "$type" ] && content="$content \033[2m[$type]\033[0m"
  [ -n "$elapsed" ] && content="$content $elapsed"
  content="$content \033[2m·\033[0m ${tok}"

  # Expand escapes to real ANSI/bytes, then emit JSON safely
  content=$(printf '%b' "$content")
  jq -nc --arg id "$id" --arg content "$content" '{id: $id, content: $content}'
done
