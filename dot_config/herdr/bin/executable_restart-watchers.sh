#!/bin/sh
# Restarts the running watcher of each herdr plugin folder, so that it runs the current code. A
# plugin with no running watcher stays stopped: no herdr session uses it.
#
# A watcher is `lockf <lock> <folder>/watch.sh watch`, which `<folder>/watch.sh ensure` starts.
#
# Usage: restart-watchers.sh <plugin folder>...

for folder in "$@"; do
  pattern="$folder/watch.sh watch"
  pids=$(pgrep -f "$pattern") || continue
  # One call: a child whose parent dies first moves to pid 1, and `pkill -P` misses it.
  pkill -P "$(echo $pids | tr ' ' ',')"
  kill $pids 2>/dev/null
  # The lock is free when lockf exits. Until then, `ensure` fails at once.
  tries=0
  while pgrep -f "$pattern" >/dev/null && [ "$tries" -lt 50 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  "$folder/watch.sh" ensure
done
