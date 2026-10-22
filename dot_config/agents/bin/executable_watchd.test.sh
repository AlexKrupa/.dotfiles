#!/usr/bin/env bash
# Checks watch.sh and watchd.sh with a fake engine, and with the real engine and a fake glab.
set -u

here=$(cd "$(dirname "$0")" && pwd)
client="$here/watch.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# shellcheck source=watch-test-fakes.sh
source "$here/watch-test-fakes.sh"
export WATCH_BIN="$here"
# shellcheck source=watch-state.sh
source "$here/watch-state.sh"
wt=$(printf %s "$d/app" | shasum | cut -c1-12)

# Fake engine: prints and empties $D/events/<key>.jsonl. If $D/events/<key>.exit has lines, it
# removes the first line, prints $D/events/<key>.err on stderr, and exits with that line.
# It adds its key and arguments to $D/args.
mkdir -p "$d/events"
cat >"$d/bin/engine" <<'EOF'
#!/usr/bin/env bash
source "$WATCH_BIN/watch-state.sh"
echo "$*" >>"$D/args"
repo=. review=0 mrs=()
while (($#)); do
  case $1 in
    --repo) repo=$2; shift 2 ;;
    --review) review=1; shift ;;
    --mr) mrs+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
f=$D/events/$(watch_key "$repo" "$review" ${mrs[@]+"${mrs[@]}"})
if [ -s "$f.exit" ]; then
  code=$(head -n1 "$f.exit")
  sed -i '' 1d "$f.exit"
  cat "$f.err" >&2 2>/dev/null
  exit "$code"
fi
cat "$f.jsonl" 2>/dev/null
: >"$f.jsonl"
EOF
chmod +x "$d/bin/engine"
export D="$d" WATCHD_ENGINE="$d/bin/engine" WATCHD_TICK=1 WATCH_CLIENT_TICK=1

sleep 600 &
session=$!
export WATCH_SESSION_PID=$session
daemon_pid() { cat "$WATCHD_DIR/daemon.pid" 2>/dev/null; }
is_daemon() { ps -o command= -p "$1" 2>/dev/null | grep -q 'watchd\.sh'; }
gone() { [ -e "$1" ] && echo no || echo yes; }
# Waits up to N seconds for a shell condition.
wait_for() {
  local n
  for n in $(seq $(($1 * 4))); do eval "$2" && return 0; sleep 0.25; done
  return 1
}
stop_daemon() {
  local pid
  pid=$(daemon_pid)
  if [ -n "$pid" ] && is_daemon "$pid"; then
    kill "$pid"
    wait_for 10 "! ps -p $pid >/dev/null"
  fi
}
reset() {
  stop_daemon
  rm -rf "$WATCHD_DIR" "$d/state/watch-gitlab" "$d/args"
  rm -f "$d/events/"*
}
trap 'stop_daemon; { kill "$session"; wait "$session"; } 2>/dev/null; rm -rf "$d"' EXIT

ev() { # kind iid
  jq -nc --arg k "$1" --argjson i "$2" \
    '{kind: $k, iid: $i, title: "Add foo", url: "u", actor: "anna", detail: "d", branch: "b"}'
}
events() { # key, lines
  printf '%s\n' "${@:2}" >>"$d/events/$1.jsonl"
}
# One client in the repo, with the arguments. Sets out, err, and code.
watch() {
  out=$(cd "$d/app" && timeout 15 "$client" --interval 1 "$@" 2>"$d/err"); code=$?
  err=$(cat "$d/err")
}
sub="$WATCHD_DIR/subs/app.json"

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
  "$(cat "$d/one") $(cat "$d/two")"
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
unset WATCHD_ENGINE
mkdir -p "$d/state/watch-gitlab"
echo '{"todos": []}' >"$d/state/watch-gitlab/app.json"
url=https://gitlab.example.com/group/sub/app/-/merge_requests
fixture todos '[{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
  "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
  "target_url": "'"$url"'/5"}]'
watch
check "e2e: real engine and fake glab give a todo event" \
  '0 {"kind":"todo","iid":5,"title":"Add foo","url":"'"$url"'/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo"}' \
  "$code $out"
export WATCHD_ENGINE="$d/bin/engine"

exit "$fail"
