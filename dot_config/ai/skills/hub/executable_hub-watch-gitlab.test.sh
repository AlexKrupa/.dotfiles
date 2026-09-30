#!/usr/bin/env bash
# Checks hub-watch-gitlab.sh with a real git repo and a fake glab.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-watch-gitlab.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake glab: `api <path>` prints $MOCK_DIR/<fixture>.json. If the file does not exist, it prints
# {} for an MR, {"approved_by": []} for approvals, and [] for a list.
# MOCK_FAIL is a path pattern: a matching call writes $MOCK_FAIL_MSG on stderr and fails.
# MOCK_NOAUTH=1 makes `auth status` fail.
mkdir -p "$d/bin" "$d/mock"
cat >"$d/bin/glab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = auth ]; then [ -z "${MOCK_NOAUTH:-}" ]; exit; fi
[ "$1" = api ] || { echo "unexpected glab call: $*" >&2; exit 2; }
if [ -n "${MOCK_FAIL:-}" ]; then
  case "$2" in $MOCK_FAIL) echo "$MOCK_FAIL_MSG" >&2; exit 1 ;; esac
fi
iid=$(echo "$2" | cut -d/ -f4 | cut -d'?' -f1)
case "$2" in
  user) f=user ;;
  projects/group%2Fsub%2Fapp) f=project ;;
  todos\?*) f=todos ;;
  projects/7/merge_requests\?author_username=*) f=mine ;;
  users/1/events\?*) f=events ;;
  projects/7/merge_requests\?*) f=commented ;;
  projects/7/merge_requests/*/approvals) f=approvals_$iid ;;
  projects/7/merge_requests/*/notes\?*) f=notes_$iid ;;
  projects/7/pipelines\?*) f=pipelines ;;
  projects/7/merge_requests/*) f=mr_$iid ;;
  *) echo "unexpected glab api path: $2" >&2; exit 2 ;;
esac
if [ -f "$MOCK_DIR/$f.json" ]; then cat "$MOCK_DIR/$f.json"; exit; fi
case "$f" in
  mr_*) echo '{}' ;;
  approvals_*) echo '{"approved_by": []}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$d/bin/glab"
export PATH="$d/bin:$PATH" MOCK_LOG="$d/calls.log" MOCK_DIR="$d/mock" XDG_STATE_HOME="$d/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig"
git config --global init.defaultBranch main

git init -q "$d/app"
git -C "$d/app" remote add origin https://gitlab.example.com/group/sub/app.git
echo '{"id": 1, "username": "me"}' >"$d/mock/user.json"
echo '{"id": 7, "default_branch": "dev/x"}' >"$d/mock/project.json"
state="$d/state/hub/app.json"
lock="$d/state/hub/app.lock"
url=https://gitlab.example.com/group/sub/app/-/merge_requests

fixture() { printf '%s\n' "$2" >"$d/mock/$1.json"; }
run() { # One check in the repo. Sets out, err, and code.
  out=$(cd "$d/app" && "$script" --once 2>"$d/err"); code=$?; err=$(cat "$d/err")
}

run
check "first check: exit 0" 0 "$code"
check "first check: no events" "" "$out"
check "first check: state saved" '[]' "$(jq -c .todos "$state")"
check "lock removed after exit" no "$([ -e "$lock" ] && echo yes || echo no)"

fixture todos '[{"id": 11, "action_name": "review_requested", "author": {"username": "anna"},
  "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo"},
  "target_url": "'"$url"'/5"}]'
run
check "new to-do item" \
  '{"kind":"todo","iid":5,"title":"Add foo","url":"'"$url"'/5","actor":"anna","detail":"review_requested","branch":"ABC-1/foo"}' \
  "$out"
run
check "same to-do item: no events" "" "$out"

export MOCK_FAIL='todos*' MOCK_FAIL_MSG='glab: 403 Forbidden (HTTP 403)'
run
check "HTTP 403: exit 1" 1 "$code"
check "HTTP 403: message" \
  "hub-watch-gitlab: HTTP 403 on todos?project_id=7&type=MergeRequest&state=pending&per_page=100. The token needs the Read permission for Todo (user boundary)." \
  "$err"

export MOCK_FAIL_MSG='dial tcp: connection refused'
: >"$MOCK_LOG"
out=$(cd "$d/app" && "$script" --interval 0 2>"$d/err"); code=$?
check "5 network errors: exit 1" 1 "$code"
check "5 network errors: 5 tries" 5 "$(grep -c '^api todos' "$MOCK_LOG")"
check "5 network errors: message" \
  "hub-watch-gitlab: todos?project_id=7&type=MergeRequest&state=pending&per_page=100: dial tcp: connection refused" \
  "$(cat "$d/err")"
unset MOCK_FAIL MOCK_FAIL_MSG

sleep 30 &
sleeper=$!
echo "$sleeper" >"$lock"
run
check "lock of a live process: exit 1" 1 "$code"
check "lock of a live process: message" \
  "hub-watch-gitlab: hub watch already runs for this repo (PID $sleeper)" "$err"
{ kill "$sleeper"; wait "$sleeper"; } 2>/dev/null
echo 999999 >"$lock"
run
check "lock of a dead process: exit 0" 0 "$code"

export MOCK_NOAUTH=1
run
check "glab not authenticated: exit 1" 1 "$code"
check "glab not authenticated: message" \
  "hub-watch-gitlab: glab is not authenticated, run: glab auth login" "$err"
unset MOCK_NOAUTH

git init -q "$d/app2"
git -C "$d/app2" remote add origin git@gitlab.example.com:group/sub/app.git
out=$(cd "$d/app2" && "$script" --once 2>&1); code=$?
check "scp-style SSH remote: same project" "0 " "$code $out"

# reset_mock: removes the state file and all fixtures except user and project.
reset_mock() {
  find "$d/mock" -name '*.json' ! -name user.json ! -name project.json -delete
  rm -f "$state"
}
mr() { # iid title state updated_at author branch [extra fields as a JSON object]
  local extra=${7:-}
  [ -n "$extra" ] || extra='{}'
  jq -nc --argjson iid "$1" --arg t "$2" --arg s "$3" --arg u "$4" --arg a "$5" --arg b "$6" \
    --arg url "$url/$1" --argjson x "$extra" \
    '{iid: $iid, title: $t, state: $s, updated_at: $u, source_branch: $b, web_url: $url,
      author: {username: $a}} + $x'
}

reset_mock
echo '{"todos": []}' >"$state"
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
fixture events '[{"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}},
  {"project_id": 8, "note": {"noteable_type": "MergeRequest", "noteable_iid": 4}},
  {"project_id": 7, "note": {"noteable_type": "Issue", "noteable_iid": 3}}]'
fixture commented "[$(mr 9 'Fix bar' merged t1 bob ABC-2/bar)]"
fixture notes_9 '[{"id": 100, "system": false, "body": "old", "author": {"username": "bob"}}]'
run
check "state with no mrs: no events for old notes" "" "$out"
check "commented MRs: only MRs of this project" \
  "api projects/7/merge_requests?state=all&iids[]=9&per_page=100" \
  "$(grep '^api projects/7/merge_requests?state' "$MOCK_LOG" | tail -n1)"

fixture commented "[$(mr 9 'Fix bar' merged t2 bob ABC-2/bar)]"
fixture notes_9 '[
  {"id": 102, "system": true, "body": "added 1 commit", "author": {"username": "anna"}},
  {"id": 101, "system": false, "body": "Please\nrename this", "author": {"username": "anna"}},
  {"id": 100, "system": false, "body": "old", "author": {"username": "bob"}}]'
run
check "new note from a different user" \
  '{"kind":"note","iid":9,"title":"Fix bar","url":"'"$url"'/9#note_101","actor":"anna","detail":"Please rename this","branch":"ABC-2/bar"}' \
  "$out"

fixture mine "[$(mr 5 'Add foo' opened t2 me ABC-1/foo)]"
fixture notes_5 '[{"id": 103, "system": false, "body": "done", "author": {"username": "me"}}]'
run
check "own note: no events" "" "$out"

long=$(printf 'x%.0s' $(seq 300))
fixture mine "[$(mr 5 'Add foo' opened t3 me ABC-1/foo)]"
fixture notes_5 '[{"id": 104, "system": false, "body": "'"$long"'",
  "author": {"username": "anna"}}]'
run
check "long note: one line" 1 "$(printf %s "$out" | grep -c "")"
check "long note: detail has 100 characters" 100 "$(jq -r '.detail | length' <<<"$out")"

: >"$MOCK_LOG"
run
check "same updated_at: no notes call" "" "$(grep '/notes' "$MOCK_LOG")"

ev() { # kind iid title actor detail branch
  jq -nc --arg k "$1" --argjson i "$2" --arg t "$3" --arg a "$4" --arg dt "$5" --arg b "$6" \
    --arg u "$url/$2" \
    '{kind: $k, iid: $i, title: $t, url: $u, actor: $a, detail: $dt, branch: $b}'
}

reset_mock
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
fixture mr_5 '{"iid": 5, "head_pipeline": {"id": 50, "status": "running"}}'
fixture approvals_5 '{"approved_by": []}'
run
check "MR state: first check has no events" "" "$out"

fixture mr_5 '{"iid": 5, "head_pipeline": {"id": 50, "status": "success"}}'
run
check "pipeline passed" "$(ev pipeline 5 'Add foo' '' 'pipeline 50 passed' ABC-1/foo)" "$out"
run
check "same pipeline: no events" "" "$out"

fixture approvals_5 '{"approved_by": [{"user": {"username": "anna"}}]}'
run
check "approval added" "$(ev approved 5 'Add foo' anna approved ABC-1/foo)" "$out"
fixture approvals_5 '{"approved_by": []}'
run
check "approval removed" "$(ev unapproved 5 'Add foo' anna 'approval removed' ABC-1/foo)" "$out"

fixture approvals_5 '{"approved_by": [{"user": {"username": "anna"}}]}'
run
fixture mine "[$(mr 5 'Add foo' merged t2 me ABC-1/foo '{"merge_user": {"username": "anna"}}')]"
run
check "merged by a different user: one event, no approval event" \
  "$(ev merged 5 'Add foo' anna merged ABC-1/foo)" "$out"

reset_mock
fixture mine "[$(mr 6 'Add baz' opened t1 me ABC-3/baz)]"
fixture mr_6 '{"iid": 6, "head_pipeline": null}'
fixture approvals_6 '{"approved_by": []}'
run
fixture mine "[$(mr 6 'Add baz' merged t2 me ABC-3/baz '{"merge_user": {"username": "me"}}')]"
run
check "merged by the user: no events" "" "$out"

reset_mock
fixture mine "[$(mr 6 'Add baz' opened t1 me ABC-3/baz)]"
run
fixture mine "[$(mr 6 'Add baz' closed t2 me ABC-3/baz '{"closed_by": {"username": "bob"}}')]"
run
check "closed by a different user" "$(ev closed 6 'Add baz' bob closed ABC-3/baz)" "$out"

reset_mock
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
fixture mr_5 '{"iid": 5, "head_pipeline": {"id": 50, "status": "running"}}'
run
fixture mr_5 '{"iid": 5, "head_pipeline": {"id": 50, "status": "failed"}}'
run
check "pipeline failed" "$(ev pipeline 5 'Add foo' '' 'pipeline 50 failed' ABC-1/foo)" "$out"

merge_mr() { # merge status, pipeline status, approver or ''
  fixture mr_5 "$(jq -nc --arg m "$1" --arg p "$2" \
    '{iid: 5, detailed_merge_status: $m, head_pipeline: {id: 50, status: $p}}')"
  fixture approvals_5 "$(jq -nc --arg a "$3" \
    '{approved_by: [$a | select(. != "") | {user: {username: .}}]}')"
}
reset_mock
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
merge_mr not_approved running ''
run
merge_mr checking success anna
run
check "transient merge status: approval and pipeline events" \
  "$(ev pipeline 5 'Add foo' '' 'pipeline 50 passed' ABC-1/foo)
$(ev approved 5 'Add foo' anna approved ABC-1/foo)" "$out"
check "transient merge status: old status stays" not_approved \
  "$(jq -r '.mrs["5"].merge_status' "$state")"
merge_mr mergeable success anna
run
check "mergeable after a transient status" \
  "$(ev mergeable 5 'Add foo' '' 'now mergeable' ABC-1/foo)" "$out"

reset_mock
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
merge_mr not_approved running ''
run
merge_mr mergeable success anna
run
check "mergeable in the same check as approval and pipeline: one event" \
  "$(ev mergeable 5 'Add foo' anna 'approved by @anna, pipeline 50 passed, now mergeable' ABC-1/foo)" \
  "$out"
merge_mr conflict success anna
run
check "merge conflict" "$(ev conflict 5 'Add foo' '' 'merge conflict' ABC-1/foo)" "$out"
merge_mr need_rebase success anna
run
check "needs rebase" "$(ev conflict 5 'Add foo' '' 'needs rebase' ABC-1/foo)" "$out"
run
check "same merge status: no events" "" "$out"

reset_mock
fixture mine "[$(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
merge_mr mergeable success ''
echo '{"todos": [], "mrs": {"5": {"updated_at": "t1", "state": "opened", "last_note_id": 0,
  "pipeline": {"id": 50, "status": "success"}, "approved_by": []}}}' >"$state"
run
check "state with no merge status: no events" "" "$out"

pipelines="$(dirname "$url")/pipelines"
reset_mock
echo '{"todos": []}' >"$state"
fixture pipelines '[{"id": 70, "status": "failed", "web_url": "'"$pipelines"'/70"}]'
: >"$MOCK_LOG"
run
check "default branch pipeline: ref and scope" \
  "api projects/7/pipelines?ref=dev%2Fx&scope=finished&per_page=1" \
  "$(grep '^api projects/7/pipelines' "$MOCK_LOG")"
check "state with no default pipeline: no events" "" "$out"
fixture pipelines '[{"id": 71, "status": "failed", "web_url": "'"$pipelines"'/71"}]'
run
check "default branch pipeline failed" \
  '{"kind":"default-failed","iid":null,"title":null,"url":"'"$pipelines"'/71","actor":"","detail":"pipeline 71 failed","branch":"dev/x"}' \
  "$out"
run
check "same default branch pipeline: no events" "" "$out"
fixture pipelines '[{"id": 72, "status": "success", "web_url": "'"$pipelines"'/72"}]'
run
check "default branch pipeline passed: no events" "" "$out"

export MOCK_FAIL='user' MOCK_FAIL_MSG='dial tcp: connection refused'
: >"$MOCK_LOG"
out=$(cd "$d/app" && "$script" --interval 0 2>"$d/err"); code=$?
check "network error at the start: 5 tries" 5 "$(grep -c '^api user' "$MOCK_LOG")"
check "network error at the start: message" \
  "hub-watch-gitlab: user: dial tcp: connection refused" "$(cat "$d/err")"
unset MOCK_FAIL MOCK_FAIL_MSG

out=$("$script" --repo "$d/app" --once 2>&1); code=$?
check "--repo from a different folder: exit 0" 0 "$code"

# The parent shell exits at once. The loop must stop after its next sleep.
(cd "$d/app" && bash -c '"$0" --interval 1 >/dev/null 2>"$1" & echo $! >"$2"; sleep 1' \
  "$script" "$d/orphan.err" "$d/orphan.pid")
orphan=$(cat "$d/orphan.pid")
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -p "$orphan" >/dev/null || break; sleep 0.5; done
check "parent gone: process stops" no "$(ps -p "$orphan" >/dev/null && echo yes || echo no)"
check "parent gone: message" "hub-watch-gitlab: the parent process is gone" \
  "$(cat "$d/orphan.err")"
kill "$orphan" 2>/dev/null

out=$("$script" --bogus 2>&1); code=$?
check "unexpected argument: exit 1" 1 "$code"
check "unexpected argument: message" "hub-watch-gitlab: unexpected argument: --bogus" "$out"

exit $fail
