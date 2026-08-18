#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/statusline-lib.sh"

input=$(cat)

now=$(date +%s)

# Model id -> display name, matching the main statusline:
# claude-opus-5 -> "Opus 5", claude-haiku-4-5-20251001 -> "Haiku 4.5"
fmt_model() {
  local id="${1#claude-}"
  id="${id%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
  local name="${id%%-*}" version="${id#*-}"
  [ "$version" = "$name" ] && version=""
  local head=$(echo "${name:0:1}" | tr '[:lower:]' '[:upper:]')
  printf '%s%s' "${head}${name:1}" "${version:+ ${version//-/.}}"
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
  {
    IFS= read -r id
    IFS= read -r desc
    IFS= read -r name
    IFS= read -r type
    IFS= read -r status
    IFS= read -r start
    IFS= read -r tokens
    IFS= read -r model
    IFS= read -r effort
    IFS= read -r win
  } < <(echo "$task" | jq -r '
    (.id // ""),
    (.description // ""),
    (.name // ""),
    (.type // ""),
    (.status // ""),
    (.startTime // ""),
    (.tokenCount // 0),
    (.model // ""),
    (.effort // ""),
    (.contextWindowSize // "")')
  [ -z "$id" ] && continue

  primary="${desc:-$name}"          # description preferred; name as fallback

  case "$status" in
    running)        dot="${C_GREEN}●${C_RESET}" ;;
    completed)      dot="${C_DIM}●${C_RESET}" ;;
    error|failed)   dot="${C_RED}●${C_RESET}" ;;
    *)              dot="${C_DIM}●${C_RESET}" ;;
  esac

  # Model + one-letter effort, as on the main statusline. Numeric effort
  # budgets and inherited effort (absent) get no suffix.
  model_seg=""
  if [ -n "$model" ]; then
    model_seg=$(fmt_model "$model")
    case "$effort" in
      ''|*[!a-z]*) ;;
      *) model_seg="$model_seg $(echo "${effort:0:1}" | tr '[:lower:]' '[:upper:]')" ;;
    esac
  fi

  # Context % when the window size is known, raw token count otherwise.
  if [ -n "$win" ] && [ "$win" -gt 0 ]; then
    pct=$(( tokens * 100 / win ))
    ctx_seg="$(pct_color "$pct")${pct}%${C_RESET}"
  else
    ctx_seg=$(fmt_tokens "$tokens")
  fi

  # <dot> <description> [<type>] · <model> <effort> · <context> · <elapsed>
  content="$dot $primary"
  [ -n "$type" ] && content="$content ${C_DIM}[$type]${C_RESET}"
  [ -n "$model_seg" ] && content="$content $sep $model_seg"
  content="$content $sep $ctx_seg"
  elapsed=$(fmt_elapsed "$start")
  [ -n "$elapsed" ] && content="$content $sep $elapsed"

  jq -nc --arg id "$id" --arg content "$content" '{id: $id, content: $content}'
done
