#!/usr/bin/env bash
# Runs no real herdr command and touches no real state, so it is safe in any pane.
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# line <round> <kind> <actor> <detail> [jq filter on the line]: one event line of the log.
line() {
  jq -nc --arg r "$1" --arg k "$2" --arg a "$3" --arg dt "$4" '{time: 1000, round: $r,
    type: "event", slug: "app", key: "app-x", mode: "stack",
    event: {kind: $k, iid: 5, title: "Add retry banner to login", url: "u", actor: $a,
      detail: $dt, branch: "ABC-1/retry"},
    sound: (if $k | IN("comment", "todo", "note") then "request" else "none" end)}
    | '"${5:-.}"
}
route() { # route <iid> <action>
  jq -nc --argjson i "$1" --arg a "$2" \
    '{time: 1000, type: "route", slug: "app", key: "app", iid: $i, action: $a}'
}
opened() { # opened <time>
  jq -nc --argjson t "$1" '{time: $t, round: "app-\($t)", type: "event", slug: "app",
    key: "app", mode: "hub", event: {kind: "opened", iid: 61, title: "Update dependency foo",
    url: "u", actor: "renovate-bot", detail: "opened", branch: "renovate/foo"},
    sound: "none"}'
}
# notify <line>...: the output of notify.jq for one group.
notify() {
  printf '%s\n' "$@" | jq -sc --argjson notify_opened '["bump"]' -f ../notify.jq
}

check "one comment" \
  '{"title":"Add retry banner to login","body":"@bob commented: \"Can we reuse?\"","sound":"request"}' \
  "$(notify "$(line r1 comment bob 'Can we reuse?')")"
check "three events" '@anna commented, @bob approved, pipeline failed' \
  "$(notify "$(line r1 comment anna Nit)" "$(line r1 approved bob approved)" \
    "$(line r1 pipeline '' 'pipeline 7 failed' '.event.jobs = ["ktlint"]')" | jq -r .body)"
check "default-failed" '["develop","Pipeline failed: unit-tests","request"]' \
  "$(notify "$(line r1 default-failed '' 'pipeline 8 failed' \
    '.event += {iid: null, title: null, branch: "develop", jobs: ["unit-tests"]}
     | .sound = "request"')" | jq -c '[.title, .body, .sound]')"
check "pipeline passed: sound none" '["Pipeline passed","none"]' \
  "$(notify "$(line r1 pipeline '' 'pipeline 9 passed')" | jq -c '[.body, .sound]')"
check "todo: review request" '@anna requested your review' \
  "$(notify "$(line r1 todo anna review_requested)" | jq -r .body)"
check "todo: other action" '@anna: build failed' \
  "$(notify "$(line r1 todo anna build_failed)" | jq -r .body)"
check "empty actor: capital letter" 'Marked it as draft' \
  "$(notify "$(line r1 draft '' 'marked as draft')" | jq -r .body)"
check "quote in the title and the body: space" '["Fix the user s login","@bob commented: \"it s odd\""]' \
  "$(notify "$(line r1 comment bob "it's odd" '.event.title = "Fix the user'"'"'s login"')" \
    | jq -c '[.title, .body]')"
check "opened with route bump" 'New dependency bump. Bump agent started.' \
  "$(notify "$(opened 1000)" "$(route 61 bump)" | jq -r .body)"
check "opened with route none: not in notify_opened" '' \
  "$(notify "$(opened 1000)" "$(route 61 none)")"
check "own-comment only: no notification" '' \
  "$(notify "$(line r1 own-comment me Done)" "$(line r1 unaddressed anna Nit)")"
check "own merge: no notification" '' \
  "$(notify "$(line r1 merged me merged '.event.own = true')")"
check "stopped" \
  '{"title":"Hub","body":"Watch stopped: watch-gitlab: HTTP 403 on todos","sound":"request"}' \
  "$(notify '{"time": 1000, "type": "stopped", "slug": "app", "key": "app", "mode": "hub",
    "title": null, "error": "watch-gitlab: HTTP 403 on todos"}')"

# sidebar <input>: the output of sidebar.jq.
sidebar() { jq -c -f ../sidebar.jq <<<"$1"; }
check "sidebar: live review with no kind" \
  '{"wR":{"watch_kind":"review","watch_stage":"watching","watch_needs":"reply"}}' \
  "$(sidebar '{"workspaces": {}, "subs": [{"mode": "review", "herdr_workspace": "wR",
    "live": true, "needs": ["reply"]}]}')"
check "sidebar: dead subscription uses the workspace file" \
  '{"wR":{"watch_kind":"bump","watch_stage":"stopped","watch_needs":""}}' \
  "$(sidebar '{"workspaces": {"wR": {"kind": "bump", "stage": "stopped"}}, "subs": [
    {"mode": "review", "herdr_workspace": "wR", "live": false, "needs": ["reply"]}]}')"

# The sweep, with a fake herdr. It logs its arguments, prints the snapshot, and fails for
# the workspace wBad.
mkdir -p "$tmp/bin" "$tmp/config"
cat >"$tmp/bin/herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/herdr.log"
case "\$*" in
  "api snapshot") cat "$tmp/snapshot.json" 2>/dev/null || exit 1 ;;
  *" wBad "*) echo "herdr: workspace_not_found" >&2; exit 1 ;;
esac
EOF
# Fake lockf: logs its arguments and starts nothing.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/lockf.log"\n' "$tmp" >"$tmp/bin/lockf"
chmod +x "$tmp/bin/herdr" "$tmp/bin/lockf"
echo '{"notify_opened": ["bump"]}' >"$tmp/config/config.json"
export PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" HERDR_PLUGIN_CONFIG_DIR="$tmp/config"
watchd=$tmp/state/watchd
plugin=$tmp/state/herdr-watch
mkdir -p "$watchd/subs" "$watchd/workspaces" "$tmp/state/watch-gitlab"
snapshot() { # snapshot <workspace id>...
  jq -nc '{result: {snapshot: {workspaces: [$ARGS.positional[] | {workspace_id: .}]}}}' \
    --args "$@" >"$tmp/snapshot.json"
}
sweep() { : >"$tmp/herdr.log"; ../watch.sh sweep; }
notes() { grep '^notification show' "$tmp/herdr.log"; }
metadata() { grep '^workspace report-metadata' "$tmp/herdr.log"; }
snapshot wT

line r0 comment bob Old >"$watchd/events.jsonl"
sweep
check "first run: starts at the end of the log" '' "$(notes)"
line r1 comment bob 'Can we reuse?' >>"$watchd/events.jsonl"
printf '{"time": 1000, "type": "event"' >>"$watchd/events.jsonl"
sweep
check "new line: one notification, not the partial line" \
  'notification show Add retry banner to login --body @bob commented: "Can we reuse?" --sound request' \
  "$(notes)"
printf ', "round": "r2", "slug": "app", "key": "app-x", "mode": "stack", "sound": "none", "event": {"kind": "approved", "iid": 5, "title": "T", "actor": "bob", "detail": "approved"}}\n' \
  >>"$watchd/events.jsonl"
sweep
check "partial line: read when it is complete" \
  'notification show T --body @bob approved --sound none' "$(notes)"

tail -n 1 "$watchd/events.jsonl" >"$watchd/events.tmp" && mv "$watchd/events.tmp" "$watchd/events.jsonl"
line r3 comment anna Later >>"$watchd/events.jsonl"
sweep
check "pruned log: no repeat, new line read" \
  'notification show Add retry banner to login --body @anna commented: "Later" --sound request' \
  "$(notes)"

opened $(($(date +%s) - 601)) >>"$watchd/events.jsonl"
sweep
check "opened with no route: dropped after 10 minutes" " 0" \
  "$(notes) $(jq length "$plugin/pending.json")"
opened "$(date +%s)" >>"$watchd/events.jsonl"
sweep
check "opened: waits for its route" " 1" "$(notes) $(jq length "$plugin/pending.json")"
route 61 bump >>"$watchd/events.jsonl"
sweep
check "opened: route in a later sweep gives the notification" \
  'notification show Update dependency foo --body New dependency bump. Bump agent started. --sound none 0' \
  "$(notes) $(jq length "$plugin/pending.json")"

echo "{\"key\": \"app-x\", \"mode\": \"stack\", \"session_pid\": $$, \"herdr_workspace\": \"wT\"}" \
  >"$watchd/subs/app-x.json"
echo '{"needs": ["failed", "reply"]}' >"$tmp/state/watch-gitlab/app-x.json"
sweep
check "live stack subscription" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=watching --token watch_needs=failed,reply' \
  "$(metadata)"
sweep
check "no change: no herdr call" '' "$(metadata)"

mv "$watchd/subs/app-x.json" "$tmp/app-x.json"
echo '{"kind": "mine", "stage": "done"}' >"$watchd/workspaces/wT.json"
sweep
check "ended with done" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=done --clear-token watch_needs' \
  "$(metadata)"

: >"$tmp/lockf.log"
../watch.sh startup
for _ in $(seq 20); do [ -s "$tmp/lockf.log" ] || sleep 0.1; done
sweep
check "startup writes all values" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=done --clear-token watch_needs' \
  "$(metadata)"
check "startup starts the watcher" "-s -k -t 0 $plugin/watch.lock $(cd .. && pwd)/watch.sh watch" \
  "$(cat "$tmp/lockf.log")"

echo '{"kind": "hub"}' >"$watchd/workspaces/wGone.json"
sweep
check "closed workspace: file removed, no call" "no " \
  "$([ -e "$watchd/workspaces/wGone.json" ] && echo yes || echo no) $(metadata)"

snapshot wBad wT wU
echo '{"kind": "review"}' >"$watchd/workspaces/wBad.json"
echo '{"kind": "bump"}' >"$watchd/workspaces/wU.json"
sweep
check "a herdr error does not stop the sweep" \
  'workspace report-metadata wU --source watch --token watch_kind=bump --clear-token watch_stage --clear-token watch_needs' \
  "$(metadata | grep -v wBad)"
sweep
check "a failed write: the next sweep tries again" 1 "$(metadata | grep -c wBad)"

mv "$tmp/snapshot.json" "$tmp/snapshot.off"
sweep
check "no herdr: no file removed" yes "$([ -e "$watchd/workspaces/wU.json" ] && echo yes || echo no)"

exit "$fail"
