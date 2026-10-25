#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

events app "$(ev todo 5)"
watch
check "hub: event comes out of the client, exit 0" "0 $(ev todo 5)" "$code $out"
check "no daemon: client starts it" yes "$(is_daemon "$(daemon_pid)" && echo yes || echo no)"
check "subscription: record" "app app hub [] 1 $session" \
  "$(jq -r '"\(.key) \(.slug) \(.mode) \(.mrs) \(.interval) \(.session_pid)"' "$sub")"

events app "$(ev note 6)"
wait_for 5 "[ -s '$WATCHD_DIR/inbox/app.jsonl' ]"
sleep 2
watch
check "events with no client wait in the inbox" "0 $(ev note 6)" "$code $out"

status=$("$client" status)
check "status: daemon" "daemon $(daemon_pid)" "$(head -n1 <<<"$status")"
check "status: repo loop" yes "$(grep -qE '^app last poll [0-9]{2}:[0-9]{2}:[0-9]{2}$' <<<"$status" \
  && echo yes || echo no)"
check "status lists the subscription" "$(printf 'app\thub\t-\tlive\t0')" \
  "$(grep '^app	' <<<"$status")"

"$client" unsubscribe --repo "$d/app"
check "unsubscribe: exit 0" 0 "$?"
check "unsubscribe removes the subscription" yes "$(gone "$sub")"

reset
check "no daemon: status" "no daemon" "$("$client" status | head -n1)"
events app "$(ev todo 5)"
events "app-$wt" "$(ev pipeline 5)"
(cd "$d/app" && timeout 15 "$client" --interval 1 >"$d/one" 2>&1) &
one=$!
(cd "$d/app" && timeout 15 "$client" --interval 1 --mr 5 >"$d/two" 2>&1) &
two=$!
wait "$one" "$two"
check "two clients at once: both get events" "$(ev todo 5) $(ev pipeline 5)" \
  "$(norow <"$d/one") $(norow <"$d/two")"
check "two clients at once: one daemon" 1 "$(grep -c 'daemon start' "$WATCHD_DIR/watchd.log")"

printf '4\n' >"$d/events/app.exit"
events app "$(ev todo 7)"
watch
check "network error: no client error, event comes" "0 $(ev todo 7)" "$code $out"
check "network error: subscription stays" no "$(gone "$sub")"
check "network error: logged, not counted" "1 0" \
  "$(grep -c 'network error' "$WATCHD_DIR/watchd.log") $(grep -c 'error 1 of 5' "$WATCHD_DIR/watchd.log")"

printf '5\n' >"$d/events/app.exit"
echo 'watch-gitlab: HTTP 403 on todos' >"$d/events/app.err"
watch
check "HTTP 403: client exit 1 with the text" "1 watch-gitlab: HTTP 403 on todos" "$code $err"
check "HTTP 403: no subscription" yes "$(gone "$sub")"

events app "$(ev todo 9)"
watch
printf '5\n' >"$d/events/app.exit"
wait_for 5 "[ -e '$WATCHD_DIR/inbox/app.error' ]"
watch
check "HTTP 403 with no client: next client exit 1, no subscription" \
  "1 watch-gitlab: HTTP 403 on todos yes" "$code $err $(gone "$sub")"

printf '1\n1\n1\n1\n1\n' >"$d/events/app.exit"
echo 'watch-gitlab: boom' >"$d/events/app.err"
: >"$d/args"
watch
check "5 other errors: exit 1" "1 watch-gitlab: boom" "$code $err"
check "5 other errors: 5 tries" 5 "$(grep -c -- "--repo $d/app\$" "$d/args")"

sleep 600 &
other=$!
events app "$(ev todo 8)"
WATCH_SESSION_PID=$other watch
{ kill "$other"; wait "$other"; } 2>/dev/null
wait_for 5 "[ ! -e '$sub' ]"
check "dead session: subscription removed" yes "$(gone "$sub")"

reset
events app "$(ev todo 5)"
WATCHD_IDLE_SECONDS=2 watch
pid=$(daemon_pid)
"$client" unsubscribe --repo "$d/app"
wait_for 6 "! ps -p $pid >/dev/null"
check "idle stop: daemon gone" "no yes" \
  "$(ps -p "$pid" >/dev/null && echo yes || echo no) $(gone "$WATCHD_DIR/daemon.pid")"

reset
git init -q "$d/gone"
git -C "$d/gone" remote add origin https://gitlab.example.com/group/sub/app.git
(cd "$d/gone" && exec timeout 15 "$client" --interval 1 >/dev/null 2>"$d/gone.err") &
gone_client=$!
wait_for 10 "[ -f '$WATCHD_DIR/subs/gone.json' ]"
rm -rf "$d/gone"
wait "$gone_client"
check "client: worktree gone: exit 1" "1 watch: the worktree is gone: $d/gone" \
  "$? $(tail -n1 "$d/gone.err")"

# The parent shell exits at once. The client must stop after its next check.
(cd "$d/app" && bash -c '"$0" --interval 1 >/dev/null 2>"$1" & echo $! >"$2"; sleep 1' \
  "$client" "$d/orphan.err" "$d/orphan.pid")
orphan=$(cat "$d/orphan.pid")
wait_for 10 "! ps -p $orphan >/dev/null"
check "client: parent gone: client stops" "no watch: the parent process is gone" \
  "$(ps -p "$orphan" >/dev/null && echo yes || echo no) $(cat "$d/orphan.err")"
kill "$orphan" 2>/dev/null

exit "$fail"
