#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

items_of() { jq -c "$2" "$WATCHD_DIR/items/$1.json" 2>/dev/null; }
rows() { jq -r .row <<<"$raw" | paste -s -d ' ' -; }
iev() { # kind iid item
  jq -nc --arg k "$1" --argjson i "$2" --arg it "$3" '{kind: $k, iid: $i, title: "Add foo",
    url: "u", actor: "anna", detail: "d", branch: "b", item: $it}'
}
reset
echo '{"present": ["todo:11"]}' >"$d/events/app.state"
events app "$(iev todo 5 todo:11)"
watch
check "item event: row 1, items file has item 1" '1 [[1,"todo:11","daemon",5]]' \
  "$(rows) $(items_of app '[.items[] | [.n, .item, .owner, .iid]]')"
events app "$(iev todo 5 todo:11)"
watch
check "second event of the same item: same row" 1 "$(rows)"
events app "$(ev reaction 5)"
watch
check "info event: new row, no item" '2 1' "$(rows) $(items_of app '.items | length')"
jq -c '.items += [{n: .next, item: "model:1", owner: "model", iid: 5}] | .next += 1' \
  "$WATCHD_DIR/items/app.json" >"$d/items.json" && mv "$d/items.json" "$WATCHD_DIR/items/app.json"
echo '{"present": []}' >"$d/events/app.state"
events app "$(ev reaction 5)"
watch
wait_for 5 "[ \"\$(items_of app '[.items[].item]')\" = '[\"model:1\"]' ]"
check "not present: item removed" no "$(items_of app '.items[].item' | grep -q todo && echo yes || echo no)"
check "model item: stays with no cause in GitLab" '["model:1"]' "$(items_of app '[.items[].item]')"
"$client" unsubscribe --repo "$d/app"
check "unsubscribe of the hub: items stay" '["model:1"]' "$(items_of app '[.items[].item]')"

reset
mkdir -p "$WATCHD_DIR/items" "$WATCH_ENGINE_DIR"
echo '{"next": 4, "items": [{"n": 3, "item": "todo:11", "owner": "daemon", "iid": 5},
  {"n": 2, "item": "todo:12", "owner": "daemon", "iid": 6}]}' >"$WATCHD_DIR/items/app.json"
echo '{"present": ["todo:11", "todo:12"]}' >"$WATCH_ENGINE_DIR/app.json"
echo '{"present": []}' >"$d/events/app-$wt-review-5.state"
events "app-$wt-review-5" "$(ev comment 5)"
watch --review --mr 5
check "live review: hub item moves" '[[1,"todo:11"]] [[2,"todo:12"]]' \
  "$(items_of "app-$wt-review-5" '[.items[] | [.n, .item]]') $(items_of app '[.items[] | [.n, .item]]')"
events "app-$wt-review-5" "$(ev merged 5)"
watch --review --mr 5
wait_for 5 "[ ! -e '$WATCHD_DIR/subs/app-$wt-review-5.json' ]"
check "ended review: items go back to the hub" '[[2,"todo:12"],[4,"todo:11"]] yes' \
  "$(items_of app '[.items[] | [.n, .item]]') $(gone "$WATCHD_DIR/items/app-$wt-review-5.json")"

reset
mkdir -p "$WATCHD_DIR/items"
echo '{"next": 2, "items": [{"n": 1, "item": "todo:11", "owner": "daemon", "iid": 5}]}' \
  >"$WATCHD_DIR/items/app.json"
events "app-$wt-review-5" "$(ev comment 5)"
watch --review --mr 5
"$client" unsubscribe --repo "$d/app" --review --mr 5
check "unsubscribe of a review: items go back to the hub" '[[2,"todo:11"]] yes' \
  "$(items_of app '[.items[] | [.n, .item]]') $(gone "$WATCHD_DIR/items/app-$wt-review-5.json")"

reset
echo '{"present": ["thread:d1"]}' >"$d/events/app-$wt.state"
events "app-$wt" "$(iev comment 5 thread:d1)" "$(iev unaddressed 5 thread:d1)"
watch --mr 5
first=$(rows)
events "app-$wt" "$(ev approved 5)" "$(iev unaddressed 5 thread:d1)"
raw=$(cd "$d/app" && timeout 5 "$client" --interval 1 --once --mr 5 2>/dev/null)
check "open item keeps its row in a second delivery" "1 1 | 2 1" "$first | $(rows)"
"$client" unsubscribe --repo "$d/app" --mr 5
check "unsubscribe of a stack: items removed" yes "$(gone "$WATCHD_DIR/items/app-$wt.json")"

reset
sleep 600 &
other=$!
echo '{"present": ["thread:d1"]}' >"$d/events/app-$wt.state"
events "app-$wt" "$(iev comment 5 thread:d1)"
WATCH_SESSION_PID=$other watch --mr 5
{ kill "$other"; wait "$other"; } 2>/dev/null
wait_for 10 "[ ! -e '$WATCHD_DIR/items/app-$wt.json' ]"
check "ended stack: items go away with the results" yes "$(gone "$WATCHD_DIR/items/app-$wt.json")"

mr_url=https://gitlab.example.com/app/-/merge_requests
pl_url=https://gitlab.example.com/app/-/pipelines
report() { # report <json> [flags]: sets out and code
  local json=$1
  shift
  out=$(cd "$d/app" && printf '%s' "$json" | "$client" report "$@" 2>&1); code=$?
}
# The report without its time line and the blank line after it, if the time line is correct.
body() {
  if grep -qE '^[0-2][0-9]:[0-5][0-9]$' <<<"$(head -n1 <<<"$out")" && [ -z "$(sed -n 2p <<<"$out")" ]
  then tail -n +3 <<<"$out"; else printf '%s\n' "$out"; fi
}
reset
echo '{"present": ["todo:11", "main-failed:develop"]}' >"$d/events/app.state"
events app \
  "$(jq -nc --arg u "$mr_url/5" '{kind: "todo", iid: 5, title: "Add foo", url: $u,
    actor: "anna", detail: "review_requested", branch: "b", item: "todo:11"}')" \
  "$(jq -nc --arg u "$pl_url/88123" '{kind: "default-failed", iid: null, title: null, url: $u,
    actor: "", detail: "pipeline 88123 failed", branch: "develop", previous: "success",
    item: "main-failed:develop", jobs: ["unit-tests"]}')" \
  "$(jq -nc --arg u "$mr_url/5#note_7" '{kind: "reaction", iid: 5, title: "Add foo", url: $u,
    actor: "bob", detail: ":tada: on your comment", branch: "b"}')"
watch
report '{"cells": {"2": "Retried, 1 of 2"}, "agent": ["2"]}'
check "report: hub table" "0
| #   | Section   | MR      | What happened                       | Proposal or result |
| --- | --------- | ------- | ----------------------------------- | ------------------ |
| 1   | Needs you | Add foo | @anna requested your review         |                    |
| 2   | Agent     | develop | Pipeline failed: unit-tests         | Retried, 1 of 2    |
| 3   | Info      | Add foo | @bob reacted :tada: on your comment |                    |

Add foo (!5) $mr_url/5
develop $pl_url/88123" "$code
$(body)"
check "report: agent closes the item" '["todo:11"]' "$(items_of app '[.items[].item]')"
report '{"cells": {"1": "Review agent started"}}'
report '{}'
check "report: cell of an open item stays" \
  "| 1   | Needs you | Add foo | @anna requested your review         | Review agent started |" \
  "$(grep '^| 1 ' <<<"$out")"
report '{"cells": {"1": "a|b"}}'
check "report: a pipe in a cell is escaped" 'a\|b' "$(grep -o 'a\\|b' <<<"$out")"
report "{\"cells\": {\"1\": \"$(printf 'x%.0s' $(seq 300))\"}}"
check "report: a long cell is cut at 200 characters" \
  "$(printf 'x%.0s' $(seq 197))..." "$(grep '^| 1 ' <<<"$out" | awk -F ' [|] ' '{print $5}' | tr -d ' |')"
report '{"close": ["1"]}'
check "report: close" "0 []" "$(grep -c 'Needs you' <<<"$out") $(items_of app '.items')"
report '{"close": ["3"]}'
check "report: close of a row with no open item hides it" "0 1" \
  "$(grep -c '^| 3 ' <<<"$out") $(grep -c '^| 1 ' <<<"$out")"
report '{"add": [{"section": "needs", "iid": 5, "what": "Fix waits, session not idle",
  "result": "Ask the agent"}]}'
check "report: add needs opens a model item" \
  '[{"item":"model:4","owner":"model","what":"Fix waits, session not idle","result":"Ask the agent"}]' \
  "$(items_of app '[.items[] | {item, owner, what, result}]')"
check "report: the model item is a Needs you row" \
  "Needs you | Add foo | Fix waits, session not idle | Ask the agent" \
  "$(grep 'Needs you' <<<"$out" | sed -E 's/ +/ /g; s/^[|] [0-9]+ [|] //; s/ [|]$//')"
"$client" unsubscribe --repo "$d/app"

reset
report '{}'
check "report: no events, no items" "0 yes" \
  "$code $(grep -qE '^[0-2][0-9]:[0-5][0-9]$' <<<"$out" && [ "$(wc -l <<<"$out" | tr -d ' ')" = 1 ] \
    && echo yes || echo no)"

reset
stack=app-$wt
work_event() { # kind iid actor detail [item] [path line]
  jq -nc --arg k "$1" --argjson i "$2" --arg a "$3" --arg dt "$4" --arg it "${5:-}" \
    --arg p "${6:-}" --arg l "${7:-}" --arg u "$mr_url/$2" '{kind: $k, iid: $i,
      title: (if $i == 123 then "Fix crash on rotation" else "Fix rotation test" end), url: $u,
      actor: $a, detail: $dt, branch: "b"}
    + (if $p == "" then {} else {path: $p, line: ($l | tonumber)} end)
    + (if $it == "" then {} else {item: $it} end)'
}
echo '{"present": ["thread:d1", "thread:d2", "pipeline:123"]}' >"$d/events/$stack.state"
events "$stack" "$(work_event comment 124 bob 'Is this flow cold?' thread:d2)"
watch --mr 123 --mr 124
report '{"cells": {"1": "Yes. Answer: it starts on the first collect."}}' --mr 123 --mr 124
events "$stack" \
  "$(work_event comment 123 anna 'Why not rememberSaveable here?' thread:d1 NoteEditor.kt 42)" \
  "$(work_event unaddressed 123 anna 'Why not rememberSaveable here?' thread:d1 NoteEditor.kt 42)" \
  "$(work_event pipeline 123 '' 'pipeline 7 failed' pipeline:123 | jq -c '.jobs = ["ktlint"]')" \
  "$(work_event approved 123 carol approved)"
watch --mr 123 --mr 124
report '{"cells": {"2": "Valid. Fix: replace the SavedStateHandle field",
  "3": "Formatted and pushed"}, "agent": ["3"]}' --mr 123 --mr 124
since=$(date -r "$(items_of "$stack" '.items[] | select(.n == 1) | .since')" +%H:%M)
check "report: work table, 2 MRs" "0
Fix crash on rotation (!123) $mr_url/123

| #   | Section   | What happened                                               | Proposal or result                             |
| --- | --------- | ----------------------------------------------------------- | ---------------------------------------------- |
| 2   | Needs you | @anna on NoteEditor.kt:42: \"Why not rememberSaveable here?\" | Valid. Fix: replace the SavedStateHandle field |
| 3   | Agent     | Pipeline failed: ktlint                                     | Formatted and pushed                           |
| 4   | Info      | @carol approved                                             |                                                |

Fix rotation test (!124) $mr_url/124

| #   | Section   | What happened                           | Proposal or result                           |
| --- | --------- | --------------------------------------- | -------------------------------------------- |
| 1   | Needs you | Since $since: @bob: \"Is this flow cold?\" | Yes. Answer: it starts on the first collect. |" "$code
$(body)"
"$client" unsubscribe --repo "$d/app" --mr 123 --mr 124

reset
echo '{"mrs": {"5": {"title": "Add foo"}, "6": {"title": "Add bar"}}, "present": []}' \
  >"$d/events/app-$wt.state"
events "app-$wt" "$(ev approved 5)"
watch --mr 5 --mr 6
report '{}' --mr 5 --mr 6
check "report: MR with no rows has no table" "0
Add foo (!5) u

| #   | Section | What happened  | Proposal or result |
| --- | ------- | -------------- | ------------------ |
| 1   | Info    | @anna approved |                    |

Add bar (!6)" "$code
$(body)"
"$client" unsubscribe --repo "$d/app" --mr 5 --mr 6

reset
mkdir -p "$WATCHD_DIR/items"
echo '{"next": 2, "items": [{"n": 1, "item": "todo:11", "owner": "daemon", "iid": 5}]}' \
  >"$WATCHD_DIR/items/app.json"
events "app-$wt" "$(ev approved 5)"
watch --mr 5
sleep 3
check "hub items with no hub record: no sweep log line, items stay" "0 yes" \
  "$(grep -c ' app results of an ended subscription removed' "$WATCHD_DIR/watchd.log") \
$([ -f "$WATCHD_DIR/items/app.json" ] && echo yes || echo no)"
"$client" unsubscribe --repo "$d/app" --mr 5

reset
echo '{"present": ["thread:d1"]}' >"$d/events/app-$wt.state"
events "app-$wt" "$(iev comment 5 thread:d1)" "$(iev unaddressed 5 thread:d1)"
watch --mr 5
events "app-$wt" "$(ev approved 5)" "$(iev unaddressed 5 thread:d1)"
watch --mr 5
report '{}' --mr 5
check "report: an old thread in a new delivery has Since" yes \
  "$(grep -qE '[|] Since [0-2][0-9]:[0-5][0-9]: @anna' <<<"$out" && echo yes || echo no)"
"$client" unsubscribe --repo "$d/app" --mr 5

reset
mkdir -p "$WATCHD_DIR/items"
echo 'not json' >"$WATCHD_DIR/items/app.json"
events app "$(ev todo 5)"
watch
check "items file not JSON: the events come, with a log line" "0 $(ev todo 5) 1" \
  "$code $out $(grep -c 'no rows' "$WATCHD_DIR/watchd.log")"
"$client" unsubscribe --repo "$d/app"

exit "$fail"
