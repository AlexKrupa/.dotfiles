#!/usr/bin/env bash
# End to end: a watch start and a watch end change the glyphs of the workspace, also after a
# restart of the herdr server. Runs its own herdr server, a test build of watchd with the fake
# engine, and the watchers of the watch and labels plugins. Touches no real state.
#
# Needs herdr, cargo, and git. Takes about 15 seconds after the first build.
set -u
set -m # Each background job gets its own process group, so that the cleanup stops all of it.

cd "$(dirname "$0")" || exit 1
labels=$(cd .. && pwd)
watch_plugin=$(cd ../../watch && pwd)
crate=$HOME/.config/agents/daemon
cargo build -q --features test-support --manifest-path "$crate/Cargo.toml" || exit 1
watchd=$crate/target/debug/watchd

# A short path: a Unix socket path has a limit of 104 bytes on macOS.
tmp=$(cd "$(mktemp -d /tmp/herdr-e2e.XXXX)" && pwd -P) || exit 1
socket=$tmp/.config/herdr/herdr.sock
jobs_started=()
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

server() { # server start|stop
  if [ "$1" = start ]; then
    (cd "$tmp" && env -u HERDR_SOCKET_PATH -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID \
      -u HERDR_WORKSPACE_ID HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" \
      XDG_STATE_HOME="$tmp/.state" herdr server >>"$tmp/server.log" 2>&1 &)
    for _ in $(seq 50); do [ -S "$socket" ] && return 0; sleep 0.2; done
    echo "the herdr server did not start, see $tmp/server.log" >&2
    exit 1
  fi
  HERDR_SOCKET_PATH=$socket herdr server stop >/dev/null 2>&1
  for _ in $(seq 50); do [ -S "$socket" ] || return 0; sleep 0.2; done
}

cleanup() {
  local pid
  for pid in "${jobs_started[@]}"; do kill -- "-$pid" 2>/dev/null; done
  [ -s "$tmp/state/watchd/daemon.pid" ] && kill "$(cat "$tmp/state/watchd/daemon.pid")" 2>/dev/null
  server stop
  rm -rf "$tmp"
}
trap cleanup EXIT

# The daemon checks the network with nc and pmset. These fakes are for the watchd clients only:
# the labels watcher needs the real nc.
mkdir -p "$tmp/bin" "$tmp/events" "$tmp/watch-config" "$tmp/labels"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/nc"
printf '#!/bin/sh\necho "Current System Capabilities are: CPU Graphics Audio Network"\n' \
  >"$tmp/bin/pmset"
chmod +x "$tmp/bin/nc" "$tmp/bin/pmset"
printf '[init]\n\tdefaultBranch = main\n' >"$tmp/gitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$tmp/gitconfig
git init -q "$tmp/app"
git -C "$tmp/app" remote add origin https://gitlab.example.com/group/app.git
echo '{"review": "R", "started": "s", "watching": "w", "stopped": "x", "done": "d"}' \
  >"$tmp/glyphs.json"
echo '{"notify_opened": []}' >"$tmp/watch-config/config.json"

# client <session pid> <watchd argument>...: a watchd client of an agent session in the workspace.
client() {
  local session=$1
  shift
  (cd "$tmp/app" && env -u HERDR_SOCKET_PATH PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" \
    WATCHD_FAKE_ENGINE="$tmp/events" WATCHD_TICK=1 WATCH_CLIENT_TICK=1 \
    WATCH_SESSION_PID="$session" HERDR_WORKSPACE_ID="$workspace" "$watchd" "$@")
}

# start <command>...: a background job that the cleanup stops.
start() {
  "$@" >/dev/null 2>&1 &
  jobs_started+=("$!")
}

# The glyphs of the workspace, from the idx token of the labels plugin.
glyphs() {
  HERDR_SOCKET_PATH=$socket herdr api snapshot 2>/dev/null | jq -r --arg w "$workspace" \
    '.result.snapshot.workspaces[] | select(.workspace_id == $w) | .tokens.idx // "" | sub("^[0-9]+ ?"; "")'
}

# wait_glyphs <expected>: the glyphs after they settle, or after 20 seconds.
wait_glyphs() {
  local value
  for _ in $(seq 100); do
    value=$(glyphs)
    [ "$value" = "$1" ] && break
    sleep 0.2
  done
  echo "$value"
}

# A labels watcher that starts before the server, for example from a shell, must wait for the
# socket.
start env HERDR_SOCKET_PATH="$socket" XDG_STATE_HOME="$tmp/state" LABELS_STATE="$tmp/labels/state.json" \
  LABELS_GLYPHS="$tmp/glyphs.json" "$labels/watch.sh" watch
sleep 2
server start
workspace=$(HERDR_SOCKET_PATH=$socket herdr workspace create --cwd "$tmp/app" \
  | jq -r .result.root_pane.workspace_id)

# The first client starts the daemon with the fake engine, before the watch plugin can.
start sleep 600
session=${jobs_started[-1]}
client "$session" kind review

start env HERDR_SOCKET_PATH="$socket" XDG_STATE_HOME="$tmp/state" \
  HERDR_PLUGIN_CONFIG_DIR="$tmp/watch-config" WATCHD="$watchd" "$watch_plugin/watch.sh" watch

check "a review with no watch is started" "R s" "$(wait_glyphs "R s")"

start client "$session" watch --review --mr 5 --interval 600
check "a watch start shows watching" "R w" "$(wait_glyphs "R w")"

kill -- "-$session"
check "the end of the session shows stopped" "R x" "$(wait_glyphs "R x")"

server stop
# Longer than the reconnect wait of the labels watcher: it must find no socket.
sleep 3
server start
check "the restored workspace has the same id" "$workspace" \
  "$(HERDR_SOCKET_PATH=$socket herdr api snapshot | jq -r --arg w "$workspace" \
    '.result.snapshot.workspaces[] | select(.workspace_id == $w) | .workspace_id')"

start sleep 600
session=${jobs_started[-1]}
start client "$session" watch --review --mr 5 --interval 600
check "after a server restart, a watch start shows watching" "R w" "$(wait_glyphs "R w")"

kill -- "-$session"
check "after a server restart, the end of the session shows stopped" "R x" "$(wait_glyphs "R x")"

exit $fail
