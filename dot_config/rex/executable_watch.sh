#!/usr/bin/env bash
# Usage: watch.sh
# The Rex watch pane. Follows the watch daemon `watchd` and prints an OSC 9 notification for each
# event of its log, with the notification rules that the herdr watch plugin also uses. Rex shows
# OSC 9 as a macOS notification. An opened event waits for its route line. The pane also prints
# each notification as a plain line. When the daemon closes the socket, the pane connects again
# and gets the log lines after the last one that it read.
set -u

notify_dir=$HOME/.config/agents/bin/watch
config=${WATCH_NOTIFY_CONFIG:-$notify_dir/notify.json}
watchd=${WATCHD:-$HOME/.local/bin/watchd}
notify_opened=$(jq -c '.notify_opened // ["bump"]' "$config" 2>/dev/null) \
  || notify_opened='["bump"]'
declare -A opened

show() {
  local note title body
  note=$(jq -c --argjson notify_opened "$notify_opened" -f "$notify_dir/notify.jq" <<<"$1") \
    || return 0
  [[ -n $note ]] || return 0
  title=$(jq -r .title <<<"$note")
  body=$(jq -r .body <<<"$note")
  printf '%s %s: %s\n' "$(date +%H:%M)" "$title" "$body"
  # Control characters would end the sequence.
  printf '\e]9;%s\a' "${title//[[:cntrl:]]/ }: ${body//[[:cntrl:]]/ }"
}

last_id=''
while :; do
  args=(follow)
  if [[ -n $last_id ]]; then args+=(--after "$last_id"); fi
  while IFS= read -r line; do
    case $(jq -r '.type // empty' <<<"$line" 2>/dev/null) in
      # The newest log id when the pane connects for the first time.
      sidebar) [[ -n $last_id ]] || last_id=$(jq -r '.last_id // empty' <<<"$line") ;;
      event)
        if [[ $(jq -r .event.kind <<<"$line") == opened ]]; then
          opened[$(jq -r '"\(.key) \(.event.iid)"' <<<"$line")]=$line
        else
          show "[$line]"
        fi
        ;;
      route)
        id=$(jq -r '"\(.key) \(.iid)"' <<<"$line")
        if [[ -n ${opened[$id]:-} ]]; then
          show "[${opened[$id]},$line]"
          unset "opened[$id]"
        fi
        ;;
      stopped) show "[$line]" ;;
    esac
    id=$(jq -r '.id // empty' <<<"$line" 2>/dev/null)
    if [[ -n $id ]]; then last_id=$id; fi
  done < <("$watchd" "${args[@]}" 2>/dev/null)
  sleep 1
done
