#!/usr/bin/env bash
# herdr caffeinate. Holds a macOS idle-sleep assertion while any agent is working.
#
# Only `working` counts. A `blocked` agent is parked waiting on the user, so sleeping loses
# nothing.
#
# Every decision lives in `decide`, which touches no processes and is covered by tests/.
#
# Needs homebrew bash 5, for the fractional `read -t` timeout in the event loop.
#
# Usage: watch.sh decide    print the decision and exit, applying nothing
#        watch.sh watch     sweep, then subscribe and sweep per burst of events
#        watch.sh ensure    spawn a detached watcher unless one is already running
#
# Env overrides, for tests and debugging:
#   CAFFEINATE_AGENTS  read this file instead of running `herdr agent list`
#   CAFFEINATE_STATE   use this state directory instead of the XDG one
#   CAFFEINATE_GRACE   seconds to hold on after the last agent stops working (default 60)

set -u

state_dir=${CAFFEINATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-caffeinate}
grace=${CAFFEINATE_GRACE:-60}
pidfile=$state_dir/watch.pid
holdfile=$state_dir/caffeinate.pid
idlefile=$state_dir/idle-since

# Without the pid files `holding` is always false, so every sweep would leak an assertion.
mkdir -p "$state_dir" || exit 1

agents() {
  if [ -n "${CAFFEINATE_AGENTS:-}" ]; then
    cat "$CAFFEINATE_AGENTS"
  else
    herdr agent list
  fi
}

holding() { [ -r "$holdfile" ] && kill -0 "$(cat "$holdfile")" 2>/dev/null; }

# Writes the idle stamp: when the agents went quiet decides the release, and nothing else
# tracks it.
decide() {
  local working now since

  working=$(agents | jq '[.result.agents[]? | select(.agent_status == "working")] | length') ||
    return 0
  [ -n "$working" ] || return 0
  now=$(date +%s)

  if [ "$working" != 0 ]; then
    rm -f "$idlefile"
    holding || printf 'hold\n'
    return 0
  fi

  holding || return 0

  # Writing before reading keeps the two branches from disagreeing about `now`.
  if [ -r "$idlefile" ]; then
    since=$(cat "$idlefile")
  else
    since=$now
    printf '%s\n' "$since" >"$idlefile"
  fi

  (( now - since >= grace )) && printf 'release\n'
  return 0
}

hold() {
  # -w releases the assertion if this watcher dies, so a crash cannot leave sleep disabled.
  # $$ is the watch process, not the ensure caller.
  caffeinate -i -w $$ &
  printf '%s\n' "$!" >"$holdfile"
}

release() {
  [ -r "$holdfile" ] && kill "$(cat "$holdfile")" 2>/dev/null
  rm -f "$holdfile" "$idlefile"
}

sweep() {
  case $(decide) in
    hold) hold ;;
    release) release ;;
  esac
}

subscribe_req=$(jq -nc '{
  id: "caffeinate", method: "events.subscribe",
  params: { subscriptions: [
    "pane.agent_status_changed", "pane.agent_detected", "pane.exited", "pane.closed"
  ] | map({type: .}) }
}')

# nc -U exits as soon as stdin reaches EOF, so stdin has to stay open for the whole stream.
stream() {
  { printf '%s\n' "$subscribe_req"; exec sleep 2147483647; } |
    nc -U "$HERDR_SOCKET_PATH"
}

# Sweep once per burst: one turn ending fires several status changes, all deciding the same.
# The read timeout drives the release - once the agents go quiet, no further events arrive.
watch() {
  trap 'release; rm -f "$pidfile"' EXIT
  sweep
  while :; do
    while :; do
      IFS= read -t "$grace" -r _
      local rc=$?
      if (( rc == 0 )); then
        local start=${EPOCHREALTIME/./}
        while read -t 0.15 -r _; do
          (( ${EPOCHREALTIME/./} - start > 500000 )) && break
        done
      elif (( rc <= 128 )); then
        break   # the server restarted, or the socket went away
      fi
      sweep
    done < <(stream)
    sleep 1
  done
}

ensure() {
  if [ -r "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi
  nohup "$0" watch >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$pidfile"
}

case ${1:-} in
  decide) decide ;;
  watch)  watch ;;
  ensure) ensure ;;
  *) printf 'usage: %s decide|watch|ensure\n' "${0##*/}" >&2; exit 2 ;;
esac
