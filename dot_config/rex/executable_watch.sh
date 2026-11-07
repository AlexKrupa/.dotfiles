#!/usr/bin/env bash
# Usage: watch.sh
# The Rex watch pane. Follows the watch daemon `watchd` and prints an OSC 9 notification for each
# event of its log, with the title and body of the herdr watch plugin (its notify.jq). Rex shows
# OSC 9 as a macOS notification. An opened event waits for its route line. The pane also prints
# each notification as a plain line. When the daemon closes the socket, the pane connects again.
set -u

plugin=$HOME/.config/herdr/plugins/watch
config=$HOME/.config/herdr/plugins/config/local.watch/config.json
watchd=${WATCHD:-$HOME/.local/bin/watchd}
notify_opened=$(jq -c '.notify_opened // ["bump"]' "$config" 2>/dev/null) \
  || notify_opened='["bump"]'
declare -A opened # "<key> <iid>": the opened event line

show() { # show <group>: a JSON array of log lines, as notify.jq takes it
  local note title body
  note=$(jq -c --argjson notify_opened "$notify_opened" -f "$plugin/notify.jq" <<<"$1") || return 0
  [[ -n $note ]] || return 0
  title=$(jq -r .title <<<"$note")
  body=$(jq -r .body <<<"$note")
  printf '%s %s: %s\n' "$(date +%H:%M)" "$title" "$body"
  # Control characters would end the sequence.
  printf '\e]9;%s\a' "${title//[[:cntrl:]]/ }: ${body//[[:cntrl:]]/ }"
}

while :; do
  while IFS= read -r line; do
    case $(jq -r '.type // empty' <<<"$line" 2>/dev/null) in
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
  done < <("$watchd" follow 2>/dev/null)
  sleep 1
done
