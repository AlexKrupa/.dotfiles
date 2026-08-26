#!/usr/bin/env bash
# herdr labels. Names each tab `N • name` after its focused pane, and numbers every
# workspace and agent with the slot its 1-9 binding uses.
#
# This file is transport only. Every naming, numbering and ownership decision is in
# policy.jq, which is pure.
#
# Needs bash 5, for `read -t 0.15` and $EPOCHREALTIME in the event loop. macOS ships
# bash 3.2, which rejects fractional read timeouts.
#
# Usage: watch.sh sweep     one pass over the session, then exit
#        watch.sh watch     sweep, then subscribe and sweep per burst of events
#        watch.sh ensure    spawn a detached watcher unless one is already running
#
# Env overrides, for tests and debugging:
#   AUTO_LABEL_SNAPSHOT  read this file instead of running `herdr api snapshot`
#   AUTO_LABEL_STATE     use this state file instead of the XDG one
#   AUTO_LABEL_DRY       set to 1 to print renames instead of applying them

set -u

root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-auto-label
state=${AUTO_LABEL_STATE:-$state_dir/state.json}

# Only the directory actually in use, so AUTO_LABEL_STATE in a test never touches the XDG one.
mkdir -p "$(dirname "$state")"
[ -s "$state" ] || printf '{}\n' >"$state"

snapshot() {
  if [ -n "${AUTO_LABEL_SNAPSHOT:-}" ]; then
    cat "$AUTO_LABEL_SNAPSHOT"
  else
    herdr api snapshot
  fi
}

# The foreground program of each tab's focused pane, as {pane_id: name}. A terminal title
# cannot answer this - lazygit, yazi and nvim leave the pane with none at all - and
# `api snapshot` holds no process information, so this costs one `pane process-info` per
# tab. Agent panes are named after their agent, so they are left out.
#
# The name is the leader of the foreground process group, which is the program the shell
# started rather than anything that program then ran itself.
programs() {
  local ids id
  ids=$(jq -r '.result.snapshot as $s
    | ($s.panes | map({key: .pane_id, value: .}) | from_entries) as $p
    | $s.layouts[].focused_pane_id
    | select($p[.] != null and $p[.].agent == null)' <<<"$1")
  for id in $ids; do
    herdr pane process-info --pane "$id"
  done | jq -sc 'map(.result.process_info | select(type == "object") | . as $i
    | { key: $i.pane_id,
        value: (first($i.foreground_processes[]
                      | select(.pid == $i.foreground_process_group_id)
                      | .name) // "") })
    | from_entries'
}

# `report-metadata` rejects the flags unless the id comes first.
meta() {
  if [ -n "$3" ]; then
    herdr "$1" report-metadata "$2" --source auto-label --token "idx=$3"
  else
    herdr "$1" report-metadata "$2" --source auto-label --clear-token idx
  fi
}

sweep() {
  local snap out first kind id value
  snap=$(snapshot) || return 0
  out=$(jq -r --slurpfile st "$state" --argjson fg "$(programs "$snap")" \
    -f "$root/policy.jq" <<<"$snap") || return 0
  [ -n "$out" ] || return 0
  first=${out%%$'\n'*}

  # State is written before the renames on purpose. Dying in between leaves a tab whose
  # label is still herdr's generated number, which the next sweep adopts again. The other
  # order leaves a renamed tab absent from state, and the next sweep reads that as a name
  # the user chose and freezes it.
  printf '%s\n' "$first" >"$state.new" && mv "$state.new" "$state"

  [ "$out" = "$first" ] && return 0   # state only: nothing to apply

  while IFS=$'\t' read -r kind id value; do
    [ -n "$id" ] || continue
    if [ -n "${AUTO_LABEL_DRY:-}" ]; then
      printf '%s %s -> %s\n' "$kind" "$id" "$value"
    elif [ "$kind" = tab ]; then
      herdr tab rename "$id" "$value" >/dev/null 2>&1
    else
      meta "$kind" "$id" "$value" >/dev/null 2>&1
    fi
  done <<<"${out#*$'\n'}"
}

pidfile=$state_dir/watch.pid

subscribe_req=$(jq -nc '{
  id: "auto-label", method: "events.subscribe",
  params: { subscriptions: [
    "pane.updated", "pane.focused", "pane.exited", "pane.closed",
    "pane.agent_detected", "layout.updated",
    "tab.created", "tab.closed", "tab.moved", "tab.renamed",
    "workspace.created", "workspace.closed", "workspace.moved", "workspace.reordered"
  ] | map({type: .}) }
}')

# Sweep once per burst, not once per event: driving yazi produces a pane.updated every
# ~100ms, and every event in a burst yields the same labels. Without the 500ms cap on the
# 150ms window, sustained churn keeps resetting the window and the label never updates.
#
# One subscription, streamed as JSON lines. nc exits as soon as its stdin reaches EOF, so
# the connection is a coprocess and this shell holds the write end open. Holding it with a
# `sleep` in a pipeline instead outlives nc, and the read loop then blocks for ever on a
# dead connection rather than seeing EOF and reconnecting.
watch() {
  # Only our own pid file: a watcher that dies after being replaced must not delete the
  # live one's, or every later `ensure` starts one more.
  trap '[ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"' EXIT
  sweep
  while :; do
    coproc conn { nc -U "$HERDR_SOCKET_PATH"; }
    local reader=${conn[0]} writer=${conn[1]}
    printf '%s\n' "$subscribe_req" >&"$writer"
    while IFS= read -r _; do
      local start=${EPOCHREALTIME/./}
      while read -t 0.15 -r _; do
        (( ${EPOCHREALTIME/./} - start > 500000 )) && break
      done
      sweep
    done <&"$reader"
    exec {reader}<&- {writer}>&-
    # bash unsets the coprocess pid as soon as it reaps it, which is most of the time here.
    [ -n "${conn_PID:-}" ] && wait "$conn_PID" 2>/dev/null
    sleep 1   # the server restarted, or the socket went away
  done
}

ensure() {
  if [ -r "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$(dirname "$pidfile")"
  nohup "$0" watch >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$pidfile"
}

case ${1:-} in
  sweep)  sweep ;;
  watch)  watch ;;
  ensure) ensure ;;
  *) printf 'usage: %s sweep|watch|ensure\n' "${0##*/}" >&2; exit 2 ;;
esac
