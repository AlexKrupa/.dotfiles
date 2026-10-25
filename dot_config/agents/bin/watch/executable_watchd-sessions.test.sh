#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

reset
start a
wait_for 10 "[ -f '$sub' ]"
first=$(client_is)
start b
check "new client of the same session: old client exit 3" 3 "$(code_of a)"
wait_for 5 "[ \"\$(client_is)\" != '$first' ]"
events app "$(ev todo 5)"
check "new client of the same session: new client gets the events" "0 $(ev todo 5)" \
  "$(code_of b) $(norow <"$d/b.out")"

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
  "$(norow 2>/dev/null <"$WATCHD_DIR/inbox/app.jsonl")"
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
  "$(norow 2>/dev/null <"$WATCHD_DIR/inbox/app-$wt.jsonl")"
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
out=$(cd "$d/app" && timeout 5 "$client" --interval 600 --once 2>"$d/err" | norow); code=$?
check "--once: events of the round" "0 $(ev todo 6)" "$code $out"

reset
events app "$(ev todo 5)"
watch --interval 600
events "app-$wt" "$(ev pipeline 5)"
watch --mr 5
before=$(cat "$WATCHD_DIR/rounds/app")
check "smallest interval used" yes \
  "$(wait_for 10 "(( \$(cat '$WATCHD_DIR/rounds/app') - before > 1 ))" && echo yes || echo no)"

reset
events app "$(ev todo 5)"
watch
sleep 600 &
other=$!
WATCH_SESSION_PID=$other "$client" unsubscribe --repo "$d/app" 2>"$d/err"
code=$?
check "unsubscribe of a different session: exit 1, no change" \
  "1 no watch: the subscription app is of session $session" "$code $(gone "$sub") $(cat "$d/err")"
{ kill "$other"; wait "$other"; } 2>/dev/null

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

exit "$fail"
