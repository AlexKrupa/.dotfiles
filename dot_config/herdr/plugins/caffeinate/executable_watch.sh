#!/usr/bin/env bash
# herdr caffeinate. Holds a macOS idle-sleep assertion while any agent is working.
#
# Only `working` counts. A `blocked` agent waits on the user, so sleeping loses nothing.
#
# Every decision is in `decide`, which touches no processes.
#
# Usage: watch.sh decide    print the decision and exit, applying nothing
#        watch.sh watch     decide once per interval, for ever
#        watch.sh ensure    spawn a detached watcher unless one is already running
#
# Env overrides, for tests and debugging:
#   CAFFEINATE_AGENTS    read this file instead of running `herdr agent list`
#   CAFFEINATE_STATE     use this state directory instead of the XDG one
#   CAFFEINATE_GRACE     seconds to hold on after the last agent stops working (default 60)
#   CAFFEINATE_INTERVAL  seconds between decisions (default 30)

set -u

state_dir=${CAFFEINATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-caffeinate}
grace=${CAFFEINATE_GRACE:-60}
interval=${CAFFEINATE_INTERVAL:-30}
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

# Writes the idle stamp. When the agents went quiet decides the release, and nothing else
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

# A poll, not a subscription: herdr takes `pane.agent_status_changed` only per pane_id, so
# no one request covers a session whose agent panes come and go. A hold placed within one
# interval is still minutes ahead of macOS idle sleep, and the release is a clock decision
# that no event announces.
watch() {
  # Only our own pid file: a watcher that dies after being replaced must not delete the
  # live one's, or every later `ensure` starts one more.
  trap 'release; [ "$(cat "$pidfile" 2>/dev/null)" = "$$" ] && rm -f "$pidfile"' EXIT
  while :; do
    sweep
    sleep "$interval"
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
