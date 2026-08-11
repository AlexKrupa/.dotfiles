#!/usr/bin/env bash
# herdr tab names. Labels each tab `N • name` after its focused pane.
#
# This file is transport only: every naming, numbering and ownership decision lives in
# policy.jq, which is pure and tested by tests/test.sh.
#
# Needs bash 5, for `read -t 0.15` and $EPOCHREALTIME in the event loop added in Task 3.
# macOS ships bash 3.2, which rejects fractional read timeouts, so this deliberately does
# not follow the bash 3.2 rule that plugins/worktree-links/link.sh keeps to.
#
# Usage: watch.sh sweep     one pass over the session, then exit
#        watch.sh watch     sweep, then subscribe and sweep per burst of events
#        watch.sh ensure    spawn a detached watcher unless one is already running
#
# Env overrides, for tests and debugging:
#   TAB_NAME_SNAPSHOT  read this file instead of running `herdr api snapshot`
#   TAB_NAME_STATE     use this state file instead of the XDG one
#   TAB_NAME_DRY       set to 1 to print renames instead of applying them

set -u

root=${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-tab-name
state=${TAB_NAME_STATE:-$state_dir/state.json}

# Only the directory actually in use, so TAB_NAME_STATE in a test never touches the XDG one.
mkdir -p "$(dirname "$state")"
[ -s "$state" ] || printf '{}\n' >"$state"

snapshot() {
  if [ -n "${TAB_NAME_SNAPSHOT:-}" ]; then
    cat "$TAB_NAME_SNAPSHOT"
  else
    herdr api snapshot
  fi
}

# One pass: read the session, let policy.jq decide, apply what changed.
sweep() {
  local out id label
  out=$(snapshot | jq -c --slurpfile st "$state" -f "$root/policy.jq") || return 0
  [ -n "$out" ] || return 0

  # State is written before the renames on purpose. Dying in between leaves a tab whose
  # label is still herdr's generated number, which the next sweep adopts again. The other
  # order would leave a renamed tab absent from state, and the next sweep would read that
  # as a name the user chose and freeze it.
  jq -c '.state' <<<"$out" >"$state.new" && mv "$state.new" "$state"

  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] || continue
    if [ -n "${TAB_NAME_DRY:-}" ]; then
      printf 'rename %s -> %s\n' "$id" "$label"
    else
      herdr tab rename "$id" "$label" >/dev/null 2>&1
    fi
  done < <(jq -r '.rename[] | [.tab_id, .label] | @tsv' <<<"$out")
}

pidfile=$state_dir/watch.pid

subscribe_req=$(jq -nc '{
  id: "tab-name", method: "events.subscribe",
  params: { subscriptions: [
    "pane.updated", "pane.focused", "pane.exited", "layout.updated",
    "tab.created", "tab.closed", "tab.moved", "tab.renamed"
  ] | map({type: .}) }
}')

# One subscription, streamed as JSON lines. nc -U exits as soon as stdin reaches EOF, so
# stdin has to stay open for the life of the stream.
stream() {
  { printf '%s\n' "$subscribe_req"; exec sleep 2147483647; } |
    nc -U "$HERDR_SOCKET_PATH"
}

# Sweep once per burst, not once per event: driving yazi produces a pane.updated every
# ~100ms, and every event in a burst yields the same labels. The 500ms cap matters as much
# as the 150ms window - without it, sustained churn keeps resetting the window and the
# label never updates at all.
watch() {
  trap 'rm -f "$pidfile"' EXIT
  sweep
  while :; do
    while IFS= read -r _; do
      local start=${EPOCHREALTIME/./}
      while read -t 0.15 -r _; do
        (( ${EPOCHREALTIME/./} - start > 500000 )) && break
      done
      sweep
    done < <(stream)
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
