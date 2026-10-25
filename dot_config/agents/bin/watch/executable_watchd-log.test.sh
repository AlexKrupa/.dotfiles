#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

log_last() { tail -n1 "$WATCHD_DIR/events.jsonl"; }
workspace_of() { jq -c . "$WATCHD_DIR/workspaces/$1.json" 2>/dev/null; }
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
kind mine
check "kind with no workspace does nothing" "0 " "$code $(ls "$WATCHD_DIR/workspaces" 2>/dev/null)"
kind review --workspace wT
check "kind: writes the workspace file" '0 {"kind":"review","stage":null}' "$code $(workspace_of wT)"
kind foo --workspace wT
check "unknown kind" "1 watch: unknown kind: foo" "$code $out"

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

exit "$fail"
