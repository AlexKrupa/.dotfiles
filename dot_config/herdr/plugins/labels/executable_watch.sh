#!/usr/bin/env bash
# herdr labels. Names each tab `N • name` after its focused pane, numbers every workspace,
# and groups the agents panel by repo with indented worktrees and idle fading.
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
#   LABELS_SNAPSHOT  read this file instead of running `herdr api snapshot`
#   LABELS_STATE     use this state file instead of the XDG one
#   LABELS_DRY       set to 1 to print renames instead of applying them

set -u

root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-labels
state=${LABELS_STATE:-$state_dir/state.json}

# Only the directory actually in use, so LABELS_STATE in a test never touches the XDG one.
mkdir -p "$(dirname "$state")"
[ -s "$state" ] || printf '{}\n' >"$state"

snapshot() {
  if [ -n "${LABELS_SNAPSHOT:-}" ]; then
    cat "$LABELS_SNAPSHOT"
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

# One call per pane or workspace, with every token that changed. `report-metadata` rejects
# the flags unless the id comes first. `name=` with no value clears the token.
meta() { # meta <kind> <id> <name=value>...
  local kind=$1 id=$2 kv args=()
  shift 2
  for kv in "$@"; do
    if [ -n "${kv#*=}" ]; then args+=(--token "$kv"); else args+=(--clear-token "${kv%=}"); fi
  done
  herdr "$kind" report-metadata "$id" --source labels "${args[@]}"
}

# The agent panes of the last sweep. Each one needs its own status subscription.
agent_panes=

sweep() {
  local snap out first f
  snap=$(snapshot) || return 0
  agent_panes=$(jq -r '[.result.snapshot.agents[]?.pane_id] | sort | join(" ")' <<<"$snap")
  out=$(jq -r --slurpfile st "$state" --argjson fg "$(programs "$snap")" \
    --argjson now "$(date +%s)" -f "$root/policy.jq" <<<"$snap") || return 0
  [ -n "$out" ] || return 0
  first=${out%%$'\n'*}

  # State is written before the renames on purpose. Dying in between leaves a tab whose
  # label is still herdr's generated number, which the next sweep adopts again. The other
  # order leaves a renamed tab absent from state, and the next sweep reads that as a name
  # the user chose and freezes it.
  printf '%s\n' "$first" >"$state.new" && mv "$state.new" "$state"

  [ "$out" = "$first" ] && return 0   # state only: nothing to apply

  # Tab is IFS whitespace, so empty fields collapse. No field is empty: a clear is `name=`.
  while IFS=$'\t' read -r -a f; do
    [ "${#f[@]}" -ge 3 ] || continue
    if [ -n "${LABELS_DRY:-}" ]; then
      printf '%s %s -> %s\n' "${f[0]}" "${f[1]}" "${f[*]:2}"
    elif [ "${f[0]}" = tab ]; then
      herdr tab rename "${f[1]}" "${f[2]}" >/dev/null 2>&1
    else
      meta "${f[@]}" >/dev/null 2>&1
    fi
  done <<<"${out#*$'\n'}"
}

# While this is set, herdr sorts the agents panel by the `ord` token and turns off its own
# grouped/priority toggle. The server forgets it on restart, so every connection sets it
# again. The server answers one request and hangs up, so it has its own connection.
view_req=$(jq -nc '{
  id: "labels-view", method: "agent.view.set",
  params: { source: "labels", label: "grouped",
            sort: [ { field: { token: "ord" }, order: "asc" } ] }
}')

set_view() { printf '%s\n' "$view_req" | nc -U "$HERDR_SOCKET_PATH" >/dev/null 2>&1; }

# An agent status change fires no pane.updated. Only a subscription to the pane itself
# reports it, so the list depends on the agents of the last sweep.
subscribe_req() { # subscribe_req <pane_id>...
  jq -nc '{
    id: "labels", method: "events.subscribe",
    params: { subscriptions: (
      ([ "pane.updated", "pane.focused", "pane.exited", "pane.closed",
         "pane.agent_detected", "layout.updated",
         "tab.created", "tab.closed", "tab.moved", "tab.renamed",
         "workspace.created", "workspace.closed", "workspace.moved", "workspace.reordered"
       ] | map({type: .}))
      + ($ARGS.positional | map({type: "pane.agent_status_changed", pane_id: .}))) }
  }' --args "$@"
}

# Sweep once per burst, not once per event: driving yazi produces a pane.updated every
# ~100ms, and every event in a burst yields the same labels. Without the 500ms cap on the
# 150ms window, sustained churn keeps resetting the window and the label never updates.
#
# One subscription, streamed as JSON lines. nc exits as soon as its stdin reaches EOF, so
# the connection is a coprocess and this shell holds the write end open. Holding it with a
# `sleep` in a pipeline instead outlives nc, and the read loop then blocks for ever on a
# dead connection rather than seeing EOF and reconnecting.
#
# A read that times out after 60 s is the clock for idle fading. A new or gone agent changes
# the subscription list, so the watcher connects again.
watch() {
  sweep
  local subscribed rc start
  while :; do
    set_view
    subscribed=$agent_panes
    coproc conn { nc -U "$HERDR_SOCKET_PATH"; }
    local reader=${conn[0]} writer=${conn[1]}
    # shellcheck disable=SC2086 # one argument per pane
    subscribe_req $subscribed >&"$writer"
    while :; do
      IFS= read -t 60 -r _; rc=$?
      if (( rc > 128 )); then
        sweep
      elif (( rc == 0 )); then
        start=${EPOCHREALTIME/./}
        while read -t 0.15 -r _; do
          (( ${EPOCHREALTIME/./} - start > 500000 )) && break
        done
        sweep
      else
        break
      fi
      [ "$agent_panes" = "$subscribed" ] || break
    done <&"$reader"
    exec {reader}<&- {writer}>&-
    # bash unsets the coprocess pid as soon as it reaps it, which is most of the time here.
    [ -n "${conn_PID:-}" ] && wait "$conn_PID" 2>/dev/null
    # EOF: the server restarted, or the socket went away.
    (( rc == 0 || rc > 128 )) || sleep 1
  done
}

# The watcher holds the lock while it lives, so a second `ensure` fails at once. Hooks can
# fire together, and a pid file check would let both start a watcher.
ensure() {
  mkdir -p "$state_dir"
  nohup lockf -s -k -t 0 "$state_dir/watch.lock" "$0" watch >/dev/null 2>&1 &
}

case ${1:-} in
  sweep)  sweep ;;
  watch)  watch ;;
  ensure) ensure ;;
  *) printf 'usage: %s sweep|watch|ensure\n' "${0##*/}" >&2; exit 2 ;;
esac
