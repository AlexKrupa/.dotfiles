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
# If $D/events/<key>.state exists, it is the saved state of the engine.
# It adds its key and arguments to $D/args. If $D/events/<key>.sleep exists, it reads the events,
# then sleeps for that number of seconds, then prints the events.
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
key=$(watch_key "$repo" "$review" ${mrs[@]+"${mrs[@]}"})
f=$D/events/$key
if [ -f "$f.state" ]; then mkdir -p "$WATCH_ENGINE_DIR"; cp "$f.state" "$WATCH_ENGINE_DIR/$key.json"; fi
if [ -s "$f.exit" ]; then
  code=$(head -n1 "$f.exit")
  sed -i '' 1d "$f.exit"
  cat "$f.err" >&2 2>/dev/null
  exit "$code"
fi
out=$(cat "$f.jsonl" 2>/dev/null)
: >"$f.jsonl"
if [ -s "$f.sleep" ]; then
  seconds=$(cat "$f.sleep")
  rm -f "$f.sleep"
  sleep "$seconds"
fi
if [ -n "$out" ]; then printf '%s\n' "$out"; fi
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

# A client in the background. Its output goes to $d/NAME.out, its exit code to $d/NAME.code.
start() { # name, client arguments
  local name=$1
  shift
  rm -f "$d/$name.code"
  (cd "$d/app" && timeout 15 "$client" --interval 1 "$@" >"$d/$name.out" 2>"$d/$name.err"
    echo $? >"$d/$name.code") &
}
code_of() { # name: waits up to 10 seconds for the exit code
  wait_for 10 "[ -s '$d/$1.code' ]"
  cat "$d/$1.code" 2>/dev/null
}
client_is() { # pid of the client in the record
  jq -r .client_pid "$sub" 2>/dev/null
}

reset
start a
wait_for 10 "[ -f '$sub' ]"
first=$(client_is)
start b
check "new client of the same session: old client exit 3" 3 "$(code_of a)"
wait_for 5 "[ \"\$(client_is)\" != '$first' ]"
events app "$(ev todo 5)"
check "new client of the same session: new client gets the events" "0 $(ev todo 5)" \
  "$(code_of b) $(cat "$d/b.out")"

first=$(client_is)
start a
wait_for 10 "[ \"\$(client_is)\" != '$first' ]"
sleep 600 &
other=$!
WATCH_SESSION_PID=$other start b
check "new session takes the key: old session client exit 3" 3 "$(code_of a)"
started=$(date +%s)
start a
check "new session takes the key: old session client exit 3 at once" "3 yes" \
  "$(code_of a) $( (($(date +%s) - started <= 3)) && echo yes || echo no)"
check "new session takes the key: replaced sessions" "[$session]" \
  "$(jq -c .replaced_sessions "$sub")"
events app "$(ev todo 6)"
code_of b >/dev/null
{ kill "$other"; wait "$other"; } 2>/dev/null

reset
events app "$(ev todo 5)"
WATCHD_CLIENT_SECONDS=2 watch
wait_for 8 "[ ! -e '$sub' ]"
check "no client for the limit: subscription ends" yes "$(gone "$sub")"

reset
events app "$(ev todo 5)"
WATCHD_CLIENT_SECONDS=2 watch
events app "$(ev note 6)"
wait_for 5 "[ -s '$WATCHD_DIR/inbox/app.jsonl' ]"
wait_for 8 "[ ! -e '$sub' ]"
check "no client for the limit: the inbox stays" "$(ev note 6)" \
  "$(cat "$WATCHD_DIR/inbox/app.jsonl" 2>/dev/null)"
watch
check "no client for the limit: the inbox comes at the next client of the same session" \
  "0 $(ev note 6)" "$code $out"

reset
events app "$(ev todo 5)"
watch
printf '5\n' >"$d/events/app.exit"
echo 'watch-gitlab: HTTP 403 on todos' >"$d/events/app.err"
wait_for 5 "[ -e '$WATCHD_DIR/inbox/app.error' ]"
sleep 600 &
other=$!
events app "$(ev todo 6)"
WATCH_SESSION_PID=$other watch
check "leftover error does not go to a new session" "0 $(ev todo 6)" "$code $out"
printf '5\n' >"$d/events/app.exit"
wait_for 5 "[ -e '$WATCHD_DIR/inbox/app.error' ]"
{ kill "$other"; wait "$other"; } 2>/dev/null
wait_for 5 "[ ! -e '$WATCHD_DIR/inbox/app.error' ]"
check "leftover of a dead session: removed" yes "$(gone "$WATCHD_DIR/inbox/app.error")"

reset
review="$WATCHD_DIR/subs/app-$wt-review-5.json"
events "app-$wt-review-5" "$(ev comment 5)"
WATCHD_CLIENT_SECONDS=2 watch --review --mr 5
start hub
wait_for 10 "grep -q -- '--repo $d/app --skip-mr 5\$' '$d/args'"
check "review: hub gets --skip-mr for the reviewed MR" yes \
  "$(grep -q -- "--repo $d/app --skip-mr 5\$" "$d/args" && echo yes || echo no)"
wait_for 8 "[ ! -e '$review' ]"
check "no client for the limit: review subscription ends" yes "$(gone "$review")"
: >"$d/args"
wait_for 5 "grep -q -- '--repo $d/app\$' '$d/args'"
check "no client for the limit: the hub gets the MR again" "yes no" \
  "$(grep -q -- "--repo $d/app\$" "$d/args" && echo yes || echo no) $(grep -q -- --skip-mr "$d/args" \
    && echo yes || echo no)"
events app "$(ev todo 7)"
code_of hub >/dev/null

reset
stack="$WATCHD_DIR/subs/app-$wt.json"
events "app-$wt" "$(ev pipeline 5)"
watch --mr 5
events "app-$wt" "$(ev merged 5)"
wait_for 5 "[ ! -e '$stack' ]"
check "all MRs merged: subscription ends" yes "$(gone "$stack")"
check "all MRs merged: inbox waits for the client" "$(ev merged 5)" \
  "$(cat "$WATCHD_DIR/inbox/app-$wt.jsonl" 2>/dev/null)"
watch --mr 5
check "all MRs merged: the client takes the inbox" "0 $(ev merged 5)" "$code $out"
check "all MRs merged: the client does not subscribe again" yes "$(gone "$stack")"

reset
events app "$(ev todo 5)"
watch --interval 600
started=$(date +%s)
out=$(cd "$d/app" && timeout 5 "$client" --interval 600 --once 2>"$d/err"); code=$?
check "--once: one round now, exit 0" "0  yes" \
  "$code $out $( (($(date +%s) - started <= 5)) && echo yes || echo no)"
events app "$(ev todo 6)"
out=$(cd "$d/app" && timeout 5 "$client" --interval 600 --once 2>"$d/err"); code=$?
check "--once: events of the round" "0 $(ev todo 6)" "$code $out"

reset
events app "$(ev todo 5)"
watch --interval 600
events "app-$wt" "$(ev pipeline 5)"
watch --mr 5
before=$(cat "$WATCHD_DIR/rounds/app")
sleep 5
check "smallest interval used" yes \
  "$( (($(cat "$WATCHD_DIR/rounds/app") - before > 1)) && echo yes || echo no)"

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
for file in watch.sh watchd.sh watch-gitlab.sh watch-lib.sh watch-state.sh repo-slug.sh; do
  cp "$here/$file" "$d/wbin/"
done
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
  "$(code_of a) $(cat "$d/a.out")"
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
  "$(code_of a) $(cat "$d/a.out")"
check "daemon killed: new daemon" yes \
  "$( [ "$(daemon_pid)" != "$old" ] && is_daemon "$(daemon_pid)" && echo yes || echo no)"

start a
wait_for 10 "[ -f '$sub' ] && [ -s '$WATCHD_DIR/repos/app.pid' ]"
kill -9 "$(daemon_pid)" "$(cat "$WATCHD_DIR/repos/app.pid")"
events app "$(ev todo 8)"
check "daemon and repo loops killed: client starts them, event not lost" "0 $(ev todo 8)" \
  "$(code_of a) $(cat "$d/a.out")"

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

sleep 600 &
other=$!
WATCH_SESSION_PID=$other "$client" unsubscribe --repo "$d/app" 2>"$d/err"
code=$?
check "unsubscribe of a different session: exit 1, no change" \
  "1 no watch: the subscription app is of session $session" "$code $(gone "$sub") $(cat "$d/err")"
{ kill "$other"; wait "$other"; } 2>/dev/null

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
  "$(code_of once) $(cat "$d/once.out")"
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

log_last() { tail -n1 "$WATCHD_DIR/events.jsonl"; }
workspace_of() { jq -c . "$WATCHD_DIR/workspaces/$1.json" 2>/dev/null; }
rm -f "$d/herdr.log"
reset
events app "$(ev todo 5)"
watch
check "routed event: log line" '["event","app","todo","request"]' \
  "$(log_last | jq -c '[.type, .key, .event.kind, .sound]')"
events app "$(ev reaction 5)"
watch
check "reaction: sound none" none "$(log_last | jq -r .sound)"
"$client" unsubscribe --repo "$d/app"

reset
stack="$WATCHD_DIR/subs/app-$wt.json"
events "app-$wt" "$(ev pipeline 5)"
HERDR_WORKSPACE_ID=wT watch --interval 600 --mr 5
check "record has the herdr workspace" wT "$(jq -r .herdr_workspace "$stack")"
events "app-$wt" "$(ev merged 5)"
HERDR_WORKSPACE_ID=wT watch --interval 600 --once --mr 5
wait_for 5 "[ ! -e '$stack' ]"
check "all MRs merged: workspace stage done" done "$(workspace_of wT | jq -r .stage)"

reset
events "app-$wt" "$(ev pipeline 5)"
HERDR_WORKSPACE_ID=wT watch --interval 600 --mr 5
"$client" unsubscribe --repo "$d/app" --mr 5
check "unsubscribe: workspace stage stopped" stopped "$(workspace_of wT | jq -r .stage)"

reset
printf '5\n' >"$d/events/app.exit"
echo 'watch-gitlab: HTTP 403 on todos' >"$d/events/app.err"
watch
check "permanent error: stopped line" '["stopped","watch-gitlab: HTTP 403 on todos",null]' \
  "$(log_last | jq -c '[.type, .error, .title]')"
reset
echo '{"mrs": {"5": {"title": "Add foo"}}, "needs": []}' >"$d/events/app-$wt.state"
printf '5\n' >"$d/events/app-$wt.exit"
echo 'watch-gitlab: HTTP 403 on graphql' >"$d/events/app-$wt.err"
watch --mr 5
check "permanent error of a stack: stopped line has the MR title" '["stopped","Add foo"]' \
  "$(log_last | jq -c '[.type, .title]')"

# kind needs no git repo: $d is not a repo.
kind() { out=$(cd "$d" && "$client" kind "$@" 2>&1); code=$?; }
reset
kind review --workspace wT
check "kind: writes the workspace file" '0 {"kind":"review","stage":null}' "$code $(workspace_of wT)"
kind foo --workspace wT
check "unknown kind" "1 watch: unknown kind: foo" "$code $out"
kind mine
check "kind with no workspace does nothing" "0 " "$code $(ls "$WATCHD_DIR/workspaces" 2>/dev/null)"

reset
events "app-$wt" "$(ev pipeline 5)"
HERDR_WORKSPACE_ID=wT watch --interval 600 --mr 5
echo '{"kind": "mine", "stage": "done"}' >"$WATCHD_DIR/workspaces/wT.json"
HERDR_WORKSPACE_ID=wT kind review
check "kind during a live watch keeps the stage" '0 {"kind":"review","stage":"done"}' \
  "$code $(workspace_of wT)"
"$client" unsubscribe --repo "$d/app" --mr 5

for mode in "stack mine app-$wt --mr 5" "review review app-$wt-review-5 --review --mr 5" \
  "hub hub app"; do
  set -- $mode
  name=$1 expected=$2 key=$3
  shift 3
  reset
  events "$key" "$(ev comment 5)"
  HERDR_WORKSPACE_ID=wT watch --interval 600 "$@"
  check "subscribe with no kind sets the kind of the mode: $name" "$expected" \
    "$(workspace_of wT | jq -r .kind)"
  "$client" unsubscribe --repo "$d/app" "$@"
done

reset
mkdir -p "$WATCHD_DIR/workspaces"
echo '{"kind": "bump"}' >"$WATCHD_DIR/workspaces/wT.json"
events "app-$wt" "$(ev pipeline 5)"
HERDR_WORKSPACE_ID=wT watch --interval 600 --mr 5
check "subscribe keeps an existing kind" bump "$(workspace_of wT | jq -r .kind)"
"$client" unsubscribe --repo "$d/app" --mr 5

reset
out=$(cd "$d/app" && "$client" route --iid 61 --action bump 2>&1); code=$?
check "route: log line" '0 ["route","app",61,"bump"]' \
  "$code $(log_last | jq -c '[.type, .key, .iid, .action]')"
out=$(cd "$d/app" && "$client" route --iid 61 --action merge 2>&1); code=$?
check "route: unknown action" "1 watch: unknown action: merge" "$code $out"

check "no herdr call" yes "$(gone "$d/herdr.log")"

reset
mkdir -p "$WATCHD_DIR" "$d/state/watch-gitlab"
now=$(date +%s)
printf '{"time": %s, "type": "route", "iid": 1}\n{"time": %s, "type": "route", "iid": 2}\n' \
  $((now - 8 * 86400)) "$now" >"$WATCHD_DIR/events.jsonl"
echo '{}' >"$d/state/watch-gitlab/old.json"
echo '{}' >"$d/state/watch-gitlab/new.json"
touch -t "$(date -v-8d +%Y%m%d%H%M)" "$d/state/watch-gitlab/old.json"
events app "$(ev todo 5)"
watch
check "old log lines go away" '[2]' \
  "$(jq -sc 'map(select(.type == "route") | .iid)' "$WATCHD_DIR/events.jsonl")"
check "old engine state goes away" "yes no" \
  "$(gone "$d/state/watch-gitlab/old.json") $(gone "$d/state/watch-gitlab/new.json")"

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

rounds_of() { cat "$WATCHD_DIR/rounds/$1" 2>/dev/null || echo 0; }
gql() { # iid
  jq -n --arg iid "$1" --arg u "$url/$1" '{data: {currentUser: {username: "me"},
    project: {mergeRequest: {iid: $iid, title: "Add foo", webUrl: $u, sourceBranch: "ABC-1/foo",
      state: "opened", draft: false, mergeUser: null, headPipeline: null,
      approvedBy: {nodes: []}, detailedMergeStatus: "NOT_APPROVED", conflicts: false,
      mergeable: false}}}}' >"$d/mock/gql_$1.json"
}
anna_note() { # id
  jq -nc --argjson id "$1" '{id: $id, body: "Why?", system: false, author: {username: "anna"},
    position: null, resolvable: true, resolved: false, resolved_by: null}'
}

reset
find "$d/mock" -name '*.json' ! -name user.json ! -name project.json -delete
gql 5
fixture events '[{"project_id": 7, "note": {"id": 300, "noteable_type": "MergeRequest",
  "noteable_iid": 5}}]'
fixture commented '[{"iid": 5, "title": "Add foo", "state": "opened", "updated_at": "t1",
  "source_branch": "ABC-1/foo", "web_url": "'"$url"'/5", "author": {"username": "bob"}}]'
start review --review --mr 5
start hub
wait_for 10 "[ \$(rounds_of app) -ge 1 ] && [ \$(rounds_of app-$wt-review-5) -ge 1 ]"
sed -i '' 's/"t1"/"t2"/' "$d/mock/commented.json"
fixture notes_5 "[$(anna_note 301)]"
fixture discussions_5 "[{\"id\": \"d301\", \"individual_note\": false, \"notes\": [$(anna_note 301)]}]"
hub_rounds=$(rounds_of app)
check "e2e review: real engine gives a comment to the review client" \
  "0 comment anna" "$(code_of review) $(jq -r '"\(.kind) \(.actor)"' "$d/review.out")"
wait_for 5 "[ \$(rounds_of app) -gt $hub_rounds ]"
check "e2e review: no note for the MR in the hub inbox" "running " \
  "$( [ -s "$d/hub.code" ] && echo stopped || echo running) $(cat "$WATCHD_DIR/inbox/app.jsonl" \
    2>/dev/null)"
"$client" unsubscribe --repo "$d/app"
code_of hub >/dev/null

reset
git -C "$d/app" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$d/app" worktree add -q "$d/app2"
wt2=$(printf %s "$d/app2" | shasum | cut -c1-12)
: >"$MOCK_LOG"
start review --interval 600 --review --mr 5
wait_for 10 "[ \$(rounds_of app-$wt-review-5) -ge 1 ]"
(cd "$d/app2" && timeout 15 "$client" --interval 600 --review --mr 5 >/dev/null 2>&1) &
bump=$!
wait_for 10 "[ \$(rounds_of app-$wt2-review-5) -ge 1 ] && [ \$(rounds_of app-$wt-review-5) -ge 2 ]"
check "review and bump on the same MR: one fetch in each round" "2 2" \
  "$(rounds_of "app-$wt-review-5") $(grep -c ' iid=5$' "$MOCK_LOG")"
"$client" unsubscribe --repo "$d/app" --review --mr 5
"$client" unsubscribe --repo "$d/app2" --review --mr 5
code_of review >/dev/null
wait "$bump"

reset
find "$d/mock" -name '*.json' ! -name user.json ! -name project.json -delete
gql 5
start stack --mr 5
wait_for 10 "[ \$(rounds_of app-$wt) -ge 1 ]"
jq '.data.project.mergeRequest.headPipeline = {id: "gid://gitlab/Ci::Pipeline/50", status: "FAILED"}' \
  "$d/mock/gql_5.json" >"$d/gql.json" && mv "$d/gql.json" "$d/mock/gql_5.json"
check "e2e stack: real engine gives a pipeline event" "0 pipeline 5 pipeline 50 failed" \
  "$(code_of stack) $(jq -r '"\(.kind) \(.iid) \(.detail)"' "$d/stack.out")"
export WATCHD_ENGINE="$d/bin/engine"

reset
stack="$WATCHD_DIR/subs/app-$wt.json"
events "app-$wt" "$(ev pipeline 5)"
watch --mr 5
events "app-$wt" "$(ev pipeline 6)"
watch --mr 5 --mr 6
check "stack: a new MR list refreshes the subscription" "[5,6]" "$(jq -c .mrs "$stack")"
start hub
wait_for 10 "[ \$(rounds_of app) -ge 2 ]"
check "stack: hub does not skip a stack MR" "yes no" \
  "$(grep -q -- "--repo $d/app\$" "$d/args" && echo yes || echo no) $(grep -q -- --skip-mr "$d/args" \
    && echo yes || echo no)"
events app "$(ev todo 5)"
code_of hub >/dev/null

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
