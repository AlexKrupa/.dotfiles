#!/bin/sh
# Usage: nvim-sidebar.sh toggle | open <file> | on-event | gc
# A full-height nvim on the right edge of the tab, one nvim for each tab. The plugin
# plugins/nvim-sidebar runs it: its toggle action runs `toggle`, a closed tab or workspace runs
# `on-event`, and the herdr start runs `gc`. bin/pluck-open runs `open`, which shows the sidebar if
# it is hidden and opens the file in it.
#
# Each tab has one headless nvim server, and the sidebar pane runs only a UI client of it. So the
# pane can close, and the nvim stays, with its buffers, undo history and language servers.
#
# A new sidebar pane gets the focus only after pane-run. Keys typed before that go to the old pane,
# not into the command line of the new shell.
#
# POSIX sh, not fish: this is key-bound.

# A plugin command can have no agents/bin on its PATH. At the end, a fake mux.sh of a test wins.
PATH=$PATH:$HOME/.config/agents/bin
state=${TMPDIR:-/tmp}/nvim-sidebar

key() { printf '%s' "$1" | tr : _; }

# macOS has no timeout command. Returns 124 if the command runs longer than $1 seconds. The kill is
# SIGKILL: a command can catch SIGTERM and exit with any status.
with_timeout() {
  seconds=$1
  shift
  "$@" &
  command_pid=$!
  (
    trap 'kill "$sleep_pid" 2>/dev/null; exit 0' TERM
    sleep "$seconds" &
    sleep_pid=$!
    wait "$sleep_pid" && kill -9 "$command_pid" 2>/dev/null
  ) >/dev/null 2>&1 &
  watcher_pid=$!
  wait "$command_pid"
  status=$?
  kill "$watcher_pid" 2>/dev/null
  if [ "$status" -eq 137 ]; then return 124; fi
  return "$status"
}

answers() { with_timeout 5 nvim --server "$1" --remote-expr 1 >/dev/null 2>&1; }

pane_in_tab() { # pane_in_tab <pane> <tab>
  herdr pane get "$1" 2>/dev/null | jq -e --arg tab "$2" '.result.pane.tab_id == $tab' >/dev/null
}

# The server does not close the connection after it replies. Without -w 3, nc waits for ever.
focus() {
  printf '{"id":"rpc","method":"pane.focus","params":{"pane_id":"%s"}}\n' "$1" |
    nc -U -w 3 "$HERDR_SOCKET_PATH" >/dev/null
}

# Sets the state of the tab of the action: tab, active, sock, pane_file, and pane if the sidebar
# is open.
context() {
  tab=${HERDR_TAB_ID:-} active=${HERDR_PANE_ID:-}
  [ -n "$tab" ] && [ -n "$active" ] || exit 0
  mkdir -p "$state" || exit 1
  sock=$state/$(key "$tab").sock
  pane_file=$state/$(key "$tab").pane
  pane=
  if [ -f "$pane_file" ] && pane_in_tab "$(cat "$pane_file")" "$tab"; then
    pane=$(cat "$pane_file")
  fi
}

show() {
  cwd=$(mux.sh pane-cwd "$active") || cwd=$HOME
  if [ -e "$sock" ]; then
    answers "$sock"
    case $? in
      0) ;;
      124)
        mux.sh notify "nvim sidebar" "nvim does not answer"
        exit 1
        ;;
      *) rm -f "$sock" ;;
    esac
  fi
  if [ ! -e "$sock" ]; then
    (cd "$cwd" && exec nohup nvim --headless --listen "$sock") >/dev/null 2>&1 &
    tries=0
    until answers "$sock"; do
      tries=$((tries + 1))
      if [ "$tries" -ge 50 ]; then
        mux.sh notify "nvim sidebar" "nvim does not start"
        exit 1
      fi
      sleep 0.1
    done
  fi

  pane=$(mux.sh tab-split "$active" "$cwd") || exit 1
  printf '%s\n' "$pane" >"$pane_file"
  mux.sh pane-run "$pane" "exec nvim --remote-ui --server '$sock'" || exit 1
  focus "$pane"
}

toggle() {
  context
  if [ -n "$pane" ]; then
    herdr pane close "$pane" >/dev/null
    rm -f "$pane_file"
  else
    show
  fi
}

open_file() { # open_file <file>
  context
  if [ -n "$pane" ]; then focus "$pane"; else show; fi
  with_timeout 5 nvim --server "$sock" --remote "$1" >/dev/null 2>&1 ||
    mux.sh notify "nvim sidebar" "nvim does not open $1"
}

stop() { # stop <key>
  sock=$state/$1.sock
  if [ -e "$sock" ]; then
    # Read before the quit: after it, the socket is gone.
    pid=$(with_timeout 5 nvim --server "$sock" --remote-expr 'getpid()' 2>/dev/null)
    with_timeout 5 nvim --server "$sock" --remote-send '<C-\><C-n>:qa!<CR>' >/dev/null 2>&1
    if [ -n "$pid" ]; then
      tries=0
      while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
        tries=$((tries + 1))
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid"; fi
    fi
  fi
  rm -f "$sock" "$state/$1.pane"
}

on_event() {
  case ${HERDR_PLUGIN_EVENT:-} in
    tab.closed) stop "$(key "$HERDR_TAB_ID")" ;;
    # HERDR_TAB_ID of this event is only the active tab of the workspace.
    workspace.closed)
      for sock in "$state/$(key "$HERDR_WORKSPACE_ID")"_*.sock; do
        [ -e "$sock" ] || continue
        name=${sock##*/}
        stop "${name%.sock}"
      done
      ;;
  esac
}

gc() {
  tabs=$(herdr tab list 2>/dev/null) || exit 0
  keys=$(printf '%s' "$tabs" | jq -r '.result.tabs[].tab_id' | tr : _) || exit 0
  for sock in "$state"/*.sock; do
    [ -e "$sock" ] || continue
    name=${sock##*/}
    printf '%s\n' "$keys" | grep -qxF "${name%.sock}" || stop "${name%.sock}"
  done
  for pane_file in "$state"/*.pane; do
    [ -e "$pane_file" ] || continue
    herdr pane get "$(cat "$pane_file")" >/dev/null 2>&1 || rm -f "$pane_file"
  done
}

case ${1:-} in
  toggle) toggle ;;
  open) open_file "$2" ;;
  on-event) on_event ;;
  gc) gc ;;
  *)
    echo "usage: nvim-sidebar.sh toggle | open <file> | on-event | gc" >&2
    exit 2
    ;;
esac
