#!/usr/bin/env bash
# Runs no real herdr command and touches no real state, so it is safe in any pane.
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
# The sweep checks start one test daemon for each state folder.
stop_daemons() {
  local dir
  for dir in "$tmp"/state*/watchd; do
    if [ -s "$dir/daemon.pid" ]; then kill "$(cat "$dir/daemon.pid")" 2>/dev/null; fi
  done
}
trap 'stop_daemons; rm -rf "$tmp"' EXIT
fail=0
now=$(date +%s)

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
  jq -nc --arg r "$1" --arg k "$2" --arg a "$3" --arg dt "$4" --argjson t "$now" '{time: $t, round: $r,
    type: "event", slug: "app", key: "app-x", mode: "stack",
    event: {kind: $k, iid: 5, title: "Add retry banner to login", url: "u", actor: $a,
      detail: $dt, branch: "ABC-1/retry"},
    sound: (if $k | IN("comment", "todo", "note") then "request" else "none" end)}
    | '"${5:-.}"
}
route() { # route <iid> <action>
  jq -nc --argjson i "$1" --arg a "$2" --argjson t "$now" \
    '{time: $t, type: "route", slug: "app", key: "app", iid: $i, action: $a}'
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
check "pull blocked: the reason" '["main","Pull blocked: the checkout has changes in tracked files","request"]' \
  "$(notify "$(line r1 pull-blocked '' 'the checkout has changes in tracked files' \
    '.event += {iid: null, title: null, branch: "main"} | .sound = "request"')" \
    | jq -c '[.title, .body, .sound]')"
check "own-comment only: no notification" '' \
  "$(notify "$(line r1 own-comment me Done)" "$(line r1 unaddressed anna Nit)")"
check "own merge: no notification" '' \
  "$(notify "$(line r1 merged me merged '.event.own = true')")"
check "stopped" \
  '{"title":"Hub","body":"Watch stopped: watchd: HTTP 403 on todos","sound":"request"}' \
  "$(notify '{"time": 1000, "type": "stopped", "slug": "app", "key": "app", "mode": "hub",
    "title": null, "error": "watchd: HTTP 403 on todos"}')"

# sidebar <input>: the output of sidebar.jq.
sidebar() { jq -c -f ../sidebar.jq <<<"$1"; }
check "sidebar: live review with no kind" \
  '{"wR":{"watch_kind":"review","watch_stage":"watching","watch_needs":"reply","watch_stack":"","watch_conflict":""}}' \
  "$(sidebar '{"worktrees": {"/r/w": {}}, "folders": {"wR": "/r/w"},
    "subs": [{"mode": "review", "repo": "/r/w", "live": true, "needs": ["reply"]}]}')"
check "sidebar: dead agent uses the worktree state" \
  '{"wR":{"watch_kind":"bump","watch_stage":"stopped","watch_needs":"","watch_stack":"","watch_conflict":""}}' \
  "$(sidebar '{"worktrees": {"/r/w": {"kind": "bump", "stage": "stopped"}}, "folders": {"wR": "/r/w"},
    "subs": [{"mode": "review", "repo": "/r/w", "live": false, "needs": ["reply"]}]}')"
check "sidebar: no live agent shows the needs of the worktree checks" \
  '{"wR":{"watch_kind":"mine","watch_stage":"done","watch_needs":"failed,reply","watch_stack":"","watch_conflict":""}}' \
  "$(sidebar '{"worktrees": {"/r/w": {"kind": "mine", "stage": "done",
    "needs": {"app-1": ["failed"], "app-1-review-5": ["reply", "failed"]}}}, "folders": {"wR": "/r/w"},
    "subs": []}')"
check "sidebar: a workspace in no worktree gets no tokens" '{}' \
  "$(sidebar '{"worktrees": {"/r/w": {"kind": "bump"}}, "folders": {"wO": "/other"}, "subs": []}')"

stack() {
  sidebar "{\"subs\": [], \"worktrees\": $1, \"folders\": {\"wS\": \"$2\"}}" \
    | jq -r '.wS.watch_stack // ""'
}
check "sidebar: stack token for a workspace in a stacked worktree" 1 \
  "$(stack '{"/r/.wt/x": {"stack": ["a", "b"]}}' /r/.wt/x)"
check "sidebar: pane folder below the worktree matches" 1 \
  "$(stack '{"/r/.wt/x": {"stack": ["a", "b"]}}' /r/.wt/x/src)"
check "sidebar: longest worktree path wins" 1 \
  "$(stack '{"/r": {"stack": ["c"]}, "/r/.wt/x": {"stack": ["a", "b"]}}' /r/.wt/x)"
check "sidebar: path prefix of a different folder does not match" '' \
  "$(stack '{"/r/a": {"stack": ["a", "b"]}}' /r/ab)"
check "sidebar: stack of one branch gives no token" '' \
  "$(stack '{"/r/.wt/x": {"stack": ["a"]}}' /r/.wt/x)"
check "sidebar: kind from the matched worktree" '["review","done"]' \
  "$(sidebar '{"subs": [], "folders": {"wS": "/r/.wt/x/src"},
    "worktrees": {"/r/.wt/x": {"stack": [], "kind": "review", "stage": "done"}}}' \
    | jq -c '[.wS.watch_kind, .wS.watch_stage]')"
check "sidebar: conflict token" 1 \
  "$(sidebar '{"subs": [], "folders": {"wS": "/r/.wt/x"},
    "worktrees": {"/r/.wt/x": {"stack": ["a"], "conflict": ["f"]}}}' | jq -r '.wS.watch_conflict')"

# order <workspaces> <tokens>: the output of order.jq. A workspace is "id:label:repo" for a linked
# worktree, "id:label:repo:parent" for a parent row, and "id:label" for a workspace in no repo.
order() {
  jq -nc --argjson tokens "$1" '{tokens: $tokens, workspaces: [$ARGS.positional[] | split(":")
    | {workspace_id: .[0], label: .[1]}
      + if .[2] then {worktree: {repo_key: .[2], is_linked_worktree: (.[3] != "parent")}}
        else {} end]}' --args "${@:2}" | jq -c -f ../order.jq
}
check "order: no kind, mine, bump, review, other kinds, each alphabetical" \
  '[{"workspace_ids":["wV","wU","wN","wM","wB","wR","wH"],"before_workspace_id":"wO"}]' \
  "$(order '{"wM": {"watch_kind": "mine"}, "wN": {"watch_kind": "mine"},
    "wR": {"watch_kind": "review"}, "wB": {"watch_kind": "bump"}, "wH": {"watch_kind": "hub"}}' \
    wP:app:r:parent wM:x:r wR:a:r wU:b:r wB:c:r wV:A:r wN:Beta:r wH:a:r wO:other)"
check "order: workspace with no tokens is first" \
  '[{"workspace_ids":["wB","wA"]}]' \
  "$(order '{"wA": {"watch_kind": "review"}}' wP:app:r:parent wA:a:r wB:b:r)"
check "order: unwatched mine sorts with no kind, then watched, debug, bump" \
  '[{"workspace_ids":["wU","wO","wW","wD","wB"]}]' \
  "$(order '{"wW": {"watch_kind": "mine", "watch_stage": "watching"},
    "wU": {"watch_kind": "mine", "watch_stage": "done"}, "wD": {"watch_kind": "debug"},
    "wB": {"watch_kind": "bump"}}' \
    wP:app:r:parent wB:ABC-0:r wD:ABC-0:r wW:ABC-1:r wO:ABC-3:r wU:ABC-2:r)"
check "order: numbers in labels sort by value" \
  '[{"workspace_ids":["wC","wB","wA"]}]' \
  "$(order '{"wA": {}}' wP:app:r:parent wA:ABC-123:r wB:ABC-23:r wC:ABC-4:r)"
check "order: sorted group gives no move" '[]' \
  "$(order '{"wB": {"watch_kind": "mine", "watch_stage": "watching"}}' wP:app:r:parent wA:z:r wB:a:r)"
check "order: each group moves alone, parents stay" \
  '[{"workspace_ids":["wA","wB"],"before_workspace_id":"wQ"}]' \
  "$(order '{"wA": {}, "wC": {}}' wP:app:r:parent wB:b:r wA:a:r wQ:lib:s:parent wC:a:s wD:b:s)"
check "order: worktrees with no open parent stay" '[]' \
  "$(order '{}' wB:b:r wA:a:r)"
check "order: a group with no tokens: no move" '[]' \
  "$(order '{}' wP:app:r:parent wB:b:r wA:a:r)"

# The test repos have no remote: each check fails before a glab call.
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
# Fake nc: logs the request and sends no reply.
printf '#!/bin/sh\ncat >>"%s/nc.log"\n' "$tmp" >"$tmp/bin/nc"
chmod +x "$tmp/bin/herdr" "$tmp/bin/lockf" "$tmp/bin/nc"
echo '{"notify_opened": ["bump"]}' >"$tmp/config/config.json"
export PATH="$tmp/bin:$PATH" XDG_STATE_HOME="$tmp/state" HERDR_PLUGIN_CONFIG_DIR="$tmp/config" \
  WATCHD_TICK=1
watchd=$tmp/state/watchd
plugin=$tmp/state/herdr-watch
mkdir -p "$watchd/subs" "$tmp/state/watch-gitlab"
snapshot() {
  jq -nc '[$ARGS.positional[] | split(":") | {id: .[0], cwd: .[1]}]
    | {result: {snapshot: {
        workspaces: map({workspace_id: .id, active_tab_id: "\(.id):t1"}),
        layouts: map({tab_id: "\(.id):t1", focused_pane_id: "\(.id):p1"}),
        panes: map({pane_id: "\(.id):p1", tab_id: "\(.id):t1", cwd: .cwd})}}}' \
    --args "$@" >"$tmp/snapshot.json"
}
repo() { git init -q "$tmp/$1"; }
client() { (cd "$1" && shift && "${WATCHD:-$HOME/.local/bin/watchd}" "$@"); } # client <folder> <args>
with_id() { jq -c --argjson id "$1" '{id: $id} + .'; } # stdin: one log line
sweep() { : >"$tmp/herdr.log"; ../watch.sh sweep; }
notes() { grep '^notification show' "$tmp/herdr.log"; }
metadata() { grep '^workspace report-metadata' "$tmp/herdr.log"; }
repo t
snapshot "wT:$tmp/t"

line r0 comment bob Old | with_id 1 >"$watchd/events.jsonl"
sweep
check "first run: starts at the end of the log" '' "$(notes)"
line r1 comment bob 'Can we reuse?' | with_id 2 >>"$watchd/events.jsonl"
sweep
check "new line: one notification" \
  'notification show Add retry banner to login --body @bob commented: "Can we reuse?" --sound request' \
  "$(notes)"
sweep
check "a line gives one notification: none at the next sweep" '' "$(notes)"

tail -n 1 "$watchd/events.jsonl" >"$watchd/events.tmp" && mv "$watchd/events.tmp" "$watchd/events.jsonl"
line r3 comment anna Later | with_id 3 >>"$watchd/events.jsonl"
sweep
check "pruned log: no repeat, new line read" \
  'notification show Add retry banner to login --body @anna commented: "Later" --sound request' \
  "$(notes)"

opened $((now - 601)) | with_id 4 >>"$watchd/events.jsonl"
sweep
check "opened with no route: dropped after 10 minutes" " 0" \
  "$(notes) $(jq length "$plugin/pending.json")"
opened "$(date +%s)" | with_id 5 >>"$watchd/events.jsonl"
sweep
check "opened: waits for its route" " 1" "$(notes) $(jq length "$plugin/pending.json")"
route 61 bump | with_id 6 >>"$watchd/events.jsonl"
sweep
check "opened: route in a later sweep gives the notification" \
  'notification show Update dependency foo --body New dependency bump. Bump agent started. --sound none 0' \
  "$(notes) $(jq length "$plugin/pending.json")"

client "$tmp/t" kind mine
jq -n --argjson pid $$ --argjson now "$(date +%s)" --arg repo "$tmp/t" '{key: "app-x", slug: "app",
  repo: $repo, mode: "stack", mrs: [5], interval: 600, session_pid: $pid, client_pid: 0,
  client_at: $now, replaced_sessions: [], ended_mrs: []}' \
  >"$watchd/subs/app-x.json"
echo '{"needs": ["failed", "reply"]}' >"$tmp/state/watch-gitlab/app-x.json"
sweep
check "live stack subscription" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=watching --token watch_needs=failed,reply --clear-token watch_stack --clear-token watch_conflict' \
  "$(metadata)"
sweep
check "no change: no herdr call" '' "$(metadata)"

snapshot "wT:$tmp/t" "wO:$tmp/other"
sweep
check "a workspace of another daemon: no write" '' "$(metadata | grep wO)"

repo c
client "$tmp/c" kind mine
snapshot "wT:$tmp/t" "wC:$tmp/c"
sweep
rm -rf "$tmp/c"
for _ in $(seq 100); do
  [ -n "$(client "$tmp/t" debug state | jq -r --arg c "$tmp/c" '.worktrees[$c] // empty')" ] \
    || break
  sleep 0.1
done
sweep
check "a workspace in the cache: cleared when its worktree goes away" \
  'workspace report-metadata wC --source watch --clear-token watch_kind --clear-token watch_stage --clear-token watch_needs --clear-token watch_stack --clear-token watch_conflict' \
  "$(metadata)"
snapshot "wT:$tmp/t"

mv "$watchd/subs/app-x.json" "$tmp/app-x.json"
state=$(ls "$watchd"/worktrees/*.json)
jq '.stage = "done"' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
sweep
check "ended with done" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=done --clear-token watch_needs --clear-token watch_stack --clear-token watch_conflict' \
  "$(metadata)"

jq -nc --arg t "$tmp/t" '{result: {snapshot: {workspaces: [
    {workspace_id: "wP", label: "app", worktree: {repo_key: "k", is_linked_worktree: false}},
    {workspace_id: "wT", label: "zeta",
     worktree: {repo_key: "k", is_linked_worktree: true, checkout_path: $t}},
    {workspace_id: "wZ", label: "alpha", worktree: {repo_key: "k", is_linked_worktree: true}}]}}}' \
  >"$tmp/snapshot.json"
: >"$tmp/nc.log"
sweep
check "unwatched mine and no kind sort together by label" \
  '{"id":"watch:order","method":"workspace.move_block","params":{"workspace_ids":["wZ","wT"]}}' \
  "$(cat "$tmp/nc.log")"
snapshot "wT:$tmp/t"

: >"$tmp/lockf.log"
../watch.sh startup
for _ in $(seq 20); do [ -s "$tmp/lockf.log" ] || sleep 0.1; done
sweep
check "startup writes all values" \
  'workspace report-metadata wT --source watch --token watch_kind=mine --token watch_stage=done --clear-token watch_needs --clear-token watch_stack --clear-token watch_conflict' \
  "$(metadata)"
check "startup starts the watcher" "-s -k -t 0 $plugin/watch.lock $(cd .. && pwd)/watch.sh watch" \
  "$(cat "$tmp/lockf.log")"

repo bad
repo u
client "$tmp/bad" kind review
client "$tmp/u" kind bump
snapshot "wBad:$tmp/bad" "wT:$tmp/t" "wU:$tmp/u"
sweep
check "a herdr error does not stop the sweep" \
  'workspace report-metadata wU --source watch --token watch_kind=bump --clear-token watch_stage --clear-token watch_needs --clear-token watch_stack --clear-token watch_conflict' \
  "$(metadata | grep -v wBad)"
sweep
check "a failed write: the next sweep tries again" 1 "$(metadata | grep -c wBad)"

mv "$tmp/snapshot.json" "$tmp/snapshot.off"
sweep
check "no herdr: the written tokens stay" true "$(jq 'has("wU")' "$plugin/tokens.json")"

mv "$tmp/snapshot.off" "$tmp/snapshot.json"
mkdir -p "$tmp/state2/watchd"
XDG_STATE_HOME=$tmp/state2 ../watch.sh sweep
line r9 comment bob Hi | with_id 1 >"$tmp/state2/watchd/events.jsonl"
: >"$tmp/herdr.log"
XDG_STATE_HOME=$tmp/state2 ../watch.sh sweep
check "no log at the first sweep: the first lines of a new log are read" 1 "$(notes | wc -l | tr -d ' ')"

mkdir -p "$tmp/state3/watchd"
XDG_STATE_HOME=$tmp/state3 ../watch.sh watch &
watcher=$!
for _ in $(seq 50); do [ -s "$tmp/state3/herdr-watch/reader" ] || sleep 0.1; done
rm "$tmp/state3/herdr-watch/pending.json" "$tmp/state3/herdr-watch/tokens.json"
line r9 comment bob Again | with_id 1 >"$tmp/state3/watchd/events.jsonl"
for _ in $(seq 80); do grep -q Again "$tmp/herdr.log" || sleep 0.1; done
kill "$watcher"
check "state files removed while the watcher runs: the next line gives the notification" 1 \
  "$(grep -c Again "$tmp/herdr.log")"

cat >"$tmp/bin/fake-watchd" <<'EOF'
#!/bin/sh
echo '{"type": "sidebar", "last_id": 0, "subs": [], "engine_needs": {}, "worktrees": {"/r/.wt/x": {"stack": ["a", "b"]}}}'
exec sleep 20
EOF
chmod +x "$tmp/bin/fake-watchd"
folder() { # folder <cwd of the focused pane of workspace wF>
  jq -nc --arg cwd "$1" '{result: {snapshot: {
    workspaces: [{workspace_id: "wF", active_tab_id: "wF:t1"}],
    layouts: [{tab_id: "wF:t1", focused_pane_id: "wF:p1"}],
    panes: [{pane_id: "wF:p1", tab_id: "wF:t1", cwd: $cwd}]}}}' >"$tmp/snapshot.json"
}
folder /elsewhere
: >"$tmp/herdr.log"
mkdir -p "$tmp/state4/watchd"
XDG_STATE_HOME=$tmp/state4 WATCHD=$tmp/bin/fake-watchd ../watch.sh watch &
watcher=$!
for _ in $(seq 50); do grep -q '^api snapshot' "$tmp/herdr.log" || sleep 0.1; done
sleep 1
folder /r/.wt/x/src
for _ in $(seq 150); do grep -q 'wF.*watch_stack=1' "$tmp/herdr.log" || sleep 0.1; done
kill "$watcher"
check "a cd into a stacked worktree shows with no new sidebar line" 1 \
  "$(grep -c 'wF.*watch_stack=1' "$tmp/herdr.log")"

exit "$fail"
