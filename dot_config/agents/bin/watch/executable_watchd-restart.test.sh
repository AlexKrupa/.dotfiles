#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

reset
events app "$(ev todo 5)"
watch
old=$(daemon_pid)
echo changed >"$WATCHD_DIR/daemon.hash"
events app "$(ev todo 6)"
watch
check "script hash changed: daemon restarts with the same PID" "0 yes" \
  "$code $( [ "$(daemon_pid)" = "$old" ] && is_daemon "$old" && echo yes || echo no)"
check "script hash changed: new hash" "$(watch_scripts_hash)" "$(cat "$WATCHD_DIR/daemon.hash")"

# A copy of the scripts, so that a check can change them under a live daemon and client.
reset
mkdir -p "$d/wbin"
for file in watch.sh watchd.sh watch-gitlab.sh watch-lib.sh watch-state.sh watch-report.jq; do
  cp "$here/$file" "$d/wbin/"
done
cp "$here/../repo-slug.sh" "$here/../git-lib.sh" "$d/"
export WATCH_BIN="$d/wbin"
start a --interval 600 --fresh
wait_for 10 "[ -f '$sub' ] && [ -s '$WATCHD_DIR/rounds/app' ]"
old=$(daemon_pid)
client_pid=$(jq -r .client_pid "$sub")
mkdir -p "$WATCH_ENGINE_DIR"
echo '{"todo": 1}' >"$WATCH_ENGINE_DIR/app.json"
# The interval is long: the first round of the new daemon gives this event.
events app "$(ev todo 5)"
before=$(cat "$WATCHD_DIR/daemon.hash")
echo '# new' >>"$d/wbin/watch.sh"
wait_for 10 "[ \"\$(cat '$WATCHD_DIR/daemon.hash')\" = '$(watch_scripts_hash)' ] &&
  grep -q 'new scripts: client restart' '$WATCHD_DIR/watchd.log'"
check "new scripts: the daemon restarts by itself" "yes $old" \
  "$( [ "$(cat "$WATCHD_DIR/daemon.hash")" = "$(watch_scripts_hash)" ] &&
  [ "$before" != "$(watch_scripts_hash)" ] && echo yes || echo no) \
$(daemon_pid)"
check "new scripts: the client restarts and gets the events" "0 $(ev todo 5)" \
  "$(code_of a) $(norow <"$d/a.out")"
check "new scripts: the client keeps its process and its flags, not --fresh" \
  "$client_pid 600 no 1" \
  "$(jq -r '"\(.client_pid) \(.interval)"' "$sub") $(gone "$WATCH_ENGINE_DIR/app.json") \
$(grep -c 'new scripts: client restart' "$WATCHD_DIR/watchd.log")"
export WATCH_BIN="$here"
reset

start a
wait_for 10 "[ -f '$sub' ]"
old=$(daemon_pid)
kill -9 "$old"
events app "$(ev todo 7)"
check "daemon killed: client starts it, event not lost" "0 $(ev todo 7)" \
  "$(code_of a) $(norow <"$d/a.out")"
check "daemon killed: new daemon" yes \
  "$( [ "$(daemon_pid)" != "$old" ] && is_daemon "$(daemon_pid)" && echo yes || echo no)"

start a
wait_for 10 "[ -f '$sub' ] && [ -s '$WATCHD_DIR/repos/app.pid' ]"
kill -9 "$(daemon_pid)" "$(cat "$WATCHD_DIR/repos/app.pid")"
events app "$(ev todo 8)"
check "daemon and repo loops killed: client starts them, event not lost" "0 $(ev todo 8)" \
  "$(code_of a) $(norow <"$d/a.out")"

reset
mkdir -p "$WATCHD_DIR"
touch "$WATCHD_DIR/restart"
events app "$(ev todo 5)"
watch
check "leftover restart file: client gets events" "0 $(ev todo 5)" "$code $out"

reset
mkdir -p "$WATCHD_DIR"
seq 12000 >"$WATCHD_DIR/watchd.log"
events app "$(ev todo 5)"
watch
check "log over 10000 lines: the daemon keeps the last 5000" 7001 \
  "$(head -n1 "$WATCHD_DIR/watchd.log")"

reset
events app "$(ev todo 5)"
watch --interval 600
echo 3 >"$d/events/app.sleep"
events app "$(ev todo 6)"
: >"$d/args"
start once --interval 600 --once
wait_for 5 "[ -s '$d/args' ]"
pid=$(cat "$WATCHD_DIR/repos/app.pid")
kill "$pid"
check "repo loop stopped during a check: event not lost" "0 $(ev todo 6)" \
  "$(code_of once) $(norow <"$d/once.out")"
check "repo loop stopped during a check: loop gone" no \
  "$(ps -p "$pid" >/dev/null && echo yes || echo no)"

reset
events app "$(ev todo 5)"
watch --interval 600
echo 3 >"$d/events/app.sleep"
events app "$(ev todo 6)"
: >"$d/args"
start once --interval 600 --once
wait_for 5 "[ -s '$d/args' ]"
events app "$(ev todo 7)"
watch --interval 600 --once
check "--once: waits for a round that starts after the poke" "0 $(ev todo 6)
$(ev todo 7)" "$code $out"

reset
events app "$(ev todo 5)"
watch
printf '#!/bin/sh\nexit 1\n' >"$d/bin/nc"
printf '4\n' >"$d/events/app.exit"
start a
wait_for 5 "grep -q 'network error' '$WATCHD_DIR/watchd.log'"
sleep 2
check "network down: no client error, subscription stays" "running no" \
  "$( [ -s "$d/a.code" ] && echo stopped || echo running) $(gone "$sub")"
"$client" unsubscribe --repo "$d/app"
code_of a >/dev/null
wait_for 15 "[ ! -e '$WATCHD_DIR/repos/app.pid' ]"
check "network down: repo loop exits when its subscriptions end" yes \
  "$(gone "$WATCHD_DIR/repos/app.pid")"
printf '#!/bin/sh\nexit 0\n' >"$d/bin/nc"

exit "$fail"
