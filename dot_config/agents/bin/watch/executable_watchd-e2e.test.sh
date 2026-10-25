#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=watchd-test-lib.sh
source "$here/watchd-test-lib.sh"

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
  '0 {"kind":"todo","iid":5,"title":"Add foo","url":"'"$url"'/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo","item":"todo:11"}' \
  "$code $out"

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

exit "$fail"
