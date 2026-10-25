#!/usr/bin/env bash
# The notifications and the sidebar values of the watch daemon `watchd`. This file is transport
# only: it reads the lines of `watchd follow` and makes the herdr calls. The decisions are in
# notify.jq and sidebar.jq, which are pure.
#
# Usage: watch.sh sweep     one pass: the lines after the last id, then exit
#        watch.sh watch     follow the daemon, and connect again when it closes the socket
#        watch.sh ensure    start a detached watcher unless one runs
#        watch.sh startup   forget the written tokens, then ensure
#
# `watchd follow` sends the sidebar state first: the workspace records, the subscriptions with
# their live state, and the needs of each subscription. Then one line for each new event log line
# and each sidebar change. Each event log line has an id.
# State of the plugin, in ${XDG_STATE_HOME:-~/.local/state}/herdr-watch/:
#   reader         the id of the last event log line read
#   pending.json   the opened events that wait for the router result of the hub
#   tokens.json    the tokens written to each workspace
# The configuration file config.json has notify_opened: the router results of an opened event
# that give a notification.

set -u

root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
state_dir=$state_home/herdr-watch
config=${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/local.watch}/config.json
watchd=${WATCHD:-$HOME/.local/bin/watchd}

mkdir -p "$state_dir"

# The id of the last event log line read, or nothing at the first run.
last_id() {
  local id
  id=$(cat "$state_dir/reader" 2>/dev/null)
  [[ $id =~ ^[0-9]+$ ]] && echo "$id"
}

# in: the new log lines. out: {groups, pending}. A group is the events of one MR in one round,
# one stopped line, or an opened event with its route line. An opened event waits up to 10
# minutes for its route line.
GROUPS_PROGRAM='
  ($pending[0] // []) as $old
  | to_entries as $new
  | [$new[].value | select(.type == "route")] as $routes
  | [($old + [$new[].value | select(.type == "event" and .event.kind == "opened")])[]
      | . as $o
      | {line: $o, route: ([$routes[] | select(.key == $o.key and .iid == $o.event.iid)][0])}]
    as $opened
  | {groups: (
        ([$new[] | select(.value.type == "stopped") | {index: .key, lines: [.value]}]
          + ([$new[] | select(.value.type == "event" and .value.event.kind != "opened")]
            | group_by([.value.round, .value.event.iid])
            | map({index: .[0].key, lines: map(.value)}))
          | sort_by(.index) | map(.lines))
        + [$opened[] | select(.route) | [.line, .route]]),
     pending: [$opened[] | select(.route == null and $now - .line.time <= 600) | .line]}'

notify() { # notify <log line>...
  local result opened_list group note
  result=$(printf '%s\n' "$@" | jq -sc --slurpfile pending "$state_dir/pending.json" \
    --argjson now "$(date +%s)" "$GROUPS_PROGRAM") || return 0
  jq -c .pending <<<"$result" >"$state_dir/pending.json"
  opened_list=$(jq -c '.notify_opened // ["bump"]' "$config" 2>/dev/null) || opened_list='["bump"]'
  jq -c '.groups[]' <<<"$result" | while IFS= read -r group; do
    note=$(jq -c --argjson notify_opened "$opened_list" -f "$root/notify.jq" <<<"$group") \
      || continue
    [ -n "$note" ] || continue
    herdr notification show "$(jq -r .title <<<"$note")" --body "$(jq -r .body <<<"$note")" \
      --sound "$(jq -r .sound <<<"$note")" >/dev/null 2>&1
  done
}

# One call for each workspace, with its 3 tokens. An empty value clears the token.
meta() { # meta <workspace id> <kind> <stage> <needs>
  local id=$1 pair args=()
  for pair in "watch_kind=$2" "watch_stage=$3" "watch_needs=$4"; do
    if [ -n "${pair#*=}" ]; then
      args+=(--token "$pair")
    else
      args+=(--clear-token "${pair%%=*}")
    fi
  done
  herdr workspace report-metadata "$id" --source watch "${args[@]}" >/dev/null 2>&1
}

# Writes the tokens that changed since the last write, only for the workspaces that herdr has.
# With no herdr answer, nothing changes. A closed workspace loses its workspace record.
sidebar() { # sidebar <sidebar line>
  local ids id desired changes kind stage needs written=''
  ids=$(herdr api snapshot 2>/dev/null | jq -c '[.result.snapshot.workspaces[].workspace_id]' \
    2>/dev/null)
  [ -n "$ids" ] || return 0
  for id in $(jq -r --argjson ids "$ids" '.workspaces | keys[] | select(IN($ids[]) | not)' <<<"$1"); do
    "$watchd" workspace forget "$id" >/dev/null 2>&1
  done
  desired=$(jq -c '{workspaces, subs: [.engine_needs as $needs | .subs[]
      | . + {needs: ($needs[.key] // [])}]}' <<<"$1" | jq -c -f "$root/sidebar.jq") || return 0
  changes=$(jq -r --argjson ids "$ids" --slurpfile cache "$state_dir/tokens.json" '
    . as $desired | $cache[0] as $cache
    | ([$desired | keys[]] + [$cache | keys[]] | unique)[] | select(IN($ids[]))
    | ($desired[.] // {watch_kind: "", watch_stage: "", watch_needs: ""}) as $value
    | select($value != $cache[.])
    | [., $value.watch_kind, $value.watch_stage, $value.watch_needs] | join("|")' <<<"$desired")
  while IFS='|' read -r id kind stage needs; do
    [ -n "$id" ] || continue
    if meta "$id" "$kind" "$stage" "$needs"; then
      written+=$(jq -nc --arg id "$id" --arg k "$kind" --arg s "$stage" --arg n "$needs" \
        '{($id): {watch_kind: $k, watch_stage: $s, watch_needs: $n}}')$'\n'
    fi
  done <<<"$changes"
  printf '%s' "$written" | jq -sc --argjson ids "$ids" --slurpfile cache "$state_dir/tokens.json" \
    '($cache[0] | with_entries(select(.key | IN($ids[])))) + (add // {})' \
    >"$state_dir/tokens.tmp" && mv "$state_dir/tokens.tmp" "$state_dir/tokens.json"
}

# One batch of follow lines. The first run starts at the end of the log: the first sidebar line
# has the newest id. The new id is saved first: a crash loses a notification, but never sends one
# two times.
handle() { # handle <line>...
  local line events=() sidebar_line='' id
  for line in "$@"; do
    case $(jq -r .type <<<"$line" 2>/dev/null) in
      sidebar) sidebar_line=$line ;;
      '') ;;
      *) events+=("$line") ;;
    esac
  done
  [ -s "$state_dir/pending.json" ] || echo '[]' >"$state_dir/pending.json"
  [ -s "$state_dir/tokens.json" ] || echo '{}' >"$state_dir/tokens.json"
  if [ -z "$(last_id)" ] && [ -n "$sidebar_line" ]; then
    jq -r '.last_id // 0' <<<"$sidebar_line" >"$state_dir/reader"
  fi
  if ((${#events[@]})); then
    id=$(printf '%s\n' "${events[@]}" | jq -s 'map(.id // 0) | max')
    if ((id > $(last_id || echo 0))); then echo "$id" >"$state_dir/reader"; fi
    notify "${events[@]}"
  fi
  if [ -n "$sidebar_line" ]; then sidebar "$sidebar_line"; fi
}

# One connection to the daemon. The lines that come within half a second are one batch. With
# --once, the pass ends at the first pause after the first line, else when the daemon closes the
# socket.
pass() { # pass [--once]
  local batch=() line got=0 status id args=(follow)
  if id=$(last_id); then args+=(--after "$id"); fi
  coproc FOLLOW { exec "$watchd" "${args[@]}" 2>/dev/null; }
  while :; do
    if IFS= read -r -t 0.5 line <&"${FOLLOW[0]}"; then
      batch+=("$line")
      got=1
      continue
    fi
    status=$?
    if ((${#batch[@]})); then handle "${batch[@]}"; batch=(); fi
    if ((status <= 128)); then break; fi
    if [ "${1:-}" = --once ] && ((got)); then break; fi
  done
  kill "$FOLLOW_PID" 2>/dev/null
  wait "$FOLLOW_PID" 2>/dev/null
}

sweep() {
  pass --once
}

watch() {
  while :; do
    pass
    sleep 1
  done
}

# The watcher holds the lock while it lives, so a second `ensure` fails at once.
ensure() {
  nohup lockf -s -k -t 0 "$state_dir/watch.lock" "$root/watch.sh" watch >/dev/null 2>&1 &
}

case ${1:-} in
  sweep) sweep ;;
  watch) watch ;;
  ensure) ensure ;;
  # A new herdr server has no tokens. A watcher from before it keeps its cache, so the next
  # sweep must write all values again.
  startup) echo '{}' >"$state_dir/tokens.json"; ensure ;;
  *) printf 'usage: %s sweep|watch|ensure|startup\n' "${0##*/}" >&2; exit 2 ;;
esac
