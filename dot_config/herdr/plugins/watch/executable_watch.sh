#!/usr/bin/env bash
# The notifications and the sidebar values of the watch daemon ~/.config/agents/bin/watchd.sh.
# This file is transport only: it reads the data of the daemon and makes the herdr calls. The
# decisions are in notify.jq and sidebar.jq, which are pure.
#
# Usage: watch.sh sweep     one pass, then exit
#        watch.sh watch     a sweep every 3 seconds
#        watch.sh ensure    start a detached watcher unless one runs
#        watch.sh startup   forget the written tokens, then ensure
#
# Data of the daemon, in ${XDG_STATE_HOME:-~/.local/state}:
#   watchd/events.jsonl        the event log: one notification for each group of lines
#   watchd/subs/*.json         the subscriptions, with their herdr workspace
#   watchd/workspaces/*.json   the kind and the end stage of each workspace
#   watch-gitlab/<key>.json    the engine state, with the needs-you values
# State of the plugin, in herdr-watch/:
#   reader         the inode of the event log and the byte offset of the next line
#   last.jsonl     the last line read
#   pending.json   the opened events that wait for the router result of the hub
#   tokens.json    the tokens written to each workspace
# The configuration file config.json has notify_opened: the router results of an opened event
# that give a notification.

set -u

root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_home=${XDG_STATE_HOME:-$HOME/.local/state}
watchd=$state_home/watchd
engine_dir=$state_home/watch-gitlab
state_dir=$state_home/herdr-watch
config=${HERDR_PLUGIN_CONFIG_DIR:-$HOME/.config/herdr/plugins/config/local.watch}/config.json
log=$watchd/events.jsonl

mkdir -p "$state_dir"

# Prints the complete lines of the event log after the last read, and saves the new position
# first: a crash loses a notification, but never sends one two times. The first run starts at
# the end. The daemon prunes the log into a new file: then the read goes on after the last line
# read, or at the start if that line is gone.
read_log() {
  local inode size old_inode offset number chunk complete
  # With no log, a log that comes later is read from its start.
  if [ ! -f "$log" ]; then
    [ -s "$state_dir/reader" ] || echo "none 0" >"$state_dir/reader"
    return 0
  fi
  inode=$(stat -f %i "$log")
  size=$(stat -f %z "$log")
  if [ ! -s "$state_dir/reader" ]; then
    echo "$inode $size" >"$state_dir/reader"
    return 0
  fi
  read -r old_inode offset <"$state_dir/reader"
  if [ "$inode" != "$old_inode" ]; then
    offset=0
    number=$(grep -n -F -x -f "$state_dir/last.jsonl" "$log" 2>/dev/null | tail -n1 | cut -d: -f1)
    if [ -n "$number" ]; then offset=$(head -n "$number" "$log" | wc -c | tr -d ' '); fi
  elif ((size < offset)); then
    offset=$size
  fi
  chunk=$(tail -c +"$((offset + 1))" "$log"; printf x)
  chunk=${chunk%x}
  # The daemon can be in the middle of a line.
  complete=${chunk%"${chunk##*$'\n'}"}
  echo "$inode $((offset + $(printf %s "$complete" | wc -c)))" >"$state_dir/reader"
  [ -n "$complete" ] || return 0
  printf %s "$complete" | tail -n1 >"$state_dir/last.jsonl"
  printf %s "$complete"
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

notify() {
  local result opened_list group note
  result=$(read_log | jq -sc --slurpfile pending "$state_dir/pending.json" \
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

subs_json() {
  local file key pid live
  for file in "$watchd"/subs/*.json; do
    [ -e "$file" ] || continue
    key=$(basename "$file" .json)
    pid=$(jq -r '.session_pid // empty' "$file" 2>/dev/null) || continue
    live=false
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then live=true; fi
    jq -c --argjson live "$live" --slurpfile engine <(cat "$engine_dir/$key.json" 2>/dev/null) \
      '. + {live: $live, needs: ($engine[0].needs // [])}' "$file" 2>/dev/null
  done | jq -sc .
}

workspaces_json() {
  local file
  for file in "$watchd"/workspaces/*.json; do
    [ -e "$file" ] || continue
    jq -c --arg id "$(basename "$file" .json)" '{($id): .}' "$file" 2>/dev/null
  done | jq -sc 'add // {}'
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
# With no herdr answer, nothing changes. A closed workspace loses its workspace file.
sidebar() {
  local ids file id desired changes kind stage needs written=''
  ids=$(herdr api snapshot 2>/dev/null | jq -c '[.result.snapshot.workspaces[].workspace_id]' \
    2>/dev/null)
  [ -n "$ids" ] || return 0
  for file in "$watchd"/workspaces/*.json; do
    [ -e "$file" ] || continue
    id=$(basename "$file" .json)
    jq -e --arg id "$id" 'index($id)' <<<"$ids" >/dev/null && continue
    # The lock of the daemon: watch_lock in watch-state.sh.
    if mkdir "$file.lock" 2>/dev/null; then
      rm -f "$file"
      rmdir "$file.lock"
    fi
  done
  desired=$(jq -nc --argjson workspaces "$(workspaces_json)" --argjson subs "$(subs_json)" \
    '{workspaces: $workspaces, subs: $subs}' | jq -c -f "$root/sidebar.jq") || return 0
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

sweep() {
  # A cleanup can remove the state files while the watcher runs.
  [ -s "$state_dir/pending.json" ] || echo '[]' >"$state_dir/pending.json"
  [ -s "$state_dir/tokens.json" ] || echo '{}' >"$state_dir/tokens.json"
  notify
  sidebar
}

watch() {
  while :; do
    sweep
    sleep 3
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
