#!/usr/bin/env bash
# Checks watch-gitlab.sh with a real git repo and a fake glab.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/watch-gitlab.sh"
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
if [ "$2" = graphql ]; then
  for a; do case $a in iid=*) iid=${a#iid=} ;; esac; done
  f="$MOCK_DIR/gql_$iid.json"
  if [ ! -f "$f" ]; then
    echo '{"data": {"currentUser": {"username": "me"}, "project": {"mergeRequest": null}}}'; exit
  fi
  cat "$f"
  # Like glab --paginate: the other pages follow the first page.
  case " $* " in *" --paginate "*) cat "$MOCK_DIR/gql_${iid}_p"[0-9].json 2>/dev/null ;; esac
  # Like glab: a response with errors also goes to stderr, and the exit code is 1.
  msg=$(jq -r '[.errors[]?.message] | join("; ")' "$f")
  if [ -n "$msg" ]; then echo "glab: $msg" >&2; exit 1; fi
  exit
fi
iid=$(echo "$2" | cut -d/ -f4 | cut -d'?' -f1)
case "$2" in
  user) f=user ;;
  projects/group%2Fsub%2Fapp) f=project ;;
  todos\?*) f=todos ;;
  users/1/events\?*) f=events ;;
  projects/7/merge_requests\?author_username=*) echo "own MRs call: $2" >&2; exit 2 ;;
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
state="$d/state/watch-gitlab/app.json"
lock="$d/state/watch-gitlab/app.lock"
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
fixture todos '[{"id": 12, "action_name": "assigned", "author": {"username": "me"},
  "target": {"iid": 6, "title": "Add baz", "source_branch": "ABC-3/baz",
    "author": {"username": "me"}},
  "target_url": "'"$url"'/6"}]'
run
check "assigned to own MR: no events" "" "$out"

export MOCK_FAIL='todos*' MOCK_FAIL_MSG='glab: 403 Forbidden (HTTP 403)'
run
check "HTTP 403: exit 1" 1 "$code"
check "HTTP 403: message" \
  "watch-gitlab: HTTP 403 on todos?project_id=7&type=MergeRequest&state=pending&per_page=100. The token needs the Read permission for Todo (user boundary)." \
  "$err"

export MOCK_FAIL_MSG='dial tcp: connection refused'
: >"$MOCK_LOG"
out=$(cd "$d/app" && "$script" --interval 0 2>"$d/err"); code=$?
check "5 network errors: exit 1" 1 "$code"
check "5 network errors: 5 tries" 5 "$(grep -c '^api todos' "$MOCK_LOG")"
check "5 network errors: message" \
  "watch-gitlab: todos?project_id=7&type=MergeRequest&state=pending&per_page=100: dial tcp: connection refused" \
  "$(cat "$d/err")"
unset MOCK_FAIL MOCK_FAIL_MSG

# An older instance runs in its loop. A new instance stops it and takes the lock.
start() { (cd "$d/app" && exec "$script" --interval 60 >/dev/null 2>"$d/$1.err") & }
lock_is() {
  for _ in $(seq 40); do [ "$(cat "$lock" 2>/dev/null)" = "$1" ] && return; sleep 0.25; done
}
start old
old=$!
lock_is "$old"
start new
new=$!
(sleep 15; kill -9 "$old") 2>/dev/null &
wait "$old"
check "older instance: exit 3" 3 "$?"
check "older instance: message" "watch-gitlab: replaced by a new watch" "$(cat "$d/old.err")"
lock_is "$new"
check "new instance: lock" "$new" "$(cat "$lock" 2>/dev/null)"
kill "$new"
wait "$new"
check "new instance stopped: lock removed" no "$([ -e "$lock" ] && echo yes || echo no)"

sleep 30 &
sleeper=$!
echo "$sleeper" >"$lock"
run
check "lock of a different program: exit 0" 0 "$code"
check "lock of a different program: not stopped" yes \
  "$(ps -p "$sleeper" >/dev/null && echo yes || echo no)"
{ kill "$sleeper"; wait "$sleeper"; } 2>/dev/null
echo 999999 >"$lock"
run
check "lock of a dead process: exit 0" 0 "$code"

export MOCK_NOAUTH=1
run
check "glab not authenticated: exit 1" 1 "$code"
check "glab not authenticated: message" \
  "watch-gitlab: glab is not authenticated, run: glab auth login" "$err"
unset MOCK_NOAUTH

git init -q "$d/app2"
git -C "$d/app2" remote add origin git@gitlab.example.com:group/sub/app.git
out=$(cd "$d/app2" && "$script" --once 2>&1); code=$?
check "scp-style SSH remote: same project" "0 " "$code $out"

# reset_mock: removes the state files and all fixtures except user and project.
reset_mock() {
  find "$d/mock" -name '*.json' ! -name user.json ! -name project.json -delete
  rm -f "$state" "$d"/state/watch-gitlab/app-*.json
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

long=$(printf 'x%.0s' $(seq 300))
fixture commented "[$(mr 9 'Fix bar' merged t3 bob ABC-2/bar)]"
fixture notes_9 '[{"id": 104, "system": false, "body": "'"$long"'",
  "author": {"username": "anna"}}]'
run
check "long note: one line" 1 "$(printf %s "$out" | grep -c "")"
check "long note: detail has 100 characters" 100 "$(jq -r '.detail | length' <<<"$out")"

: >"$MOCK_LOG"
run
check "same updated_at: no notes call" "" "$(grep '/notes' "$MOCK_LOG")"

fixture events '[{"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 9}},
  {"project_id": 7, "note": {"noteable_type": "MergeRequest", "noteable_iid": 5}}]'
fixture commented "[$(mr 9 'Fix bar' merged t3 bob ABC-2/bar), $(mr 5 'Add foo' opened t1 me ABC-1/foo)]"
run
fixture commented "[$(mr 9 'Fix bar' merged t3 bob ABC-2/bar), $(mr 5 'Add foo' opened t2 me ABC-1/foo)]"
fixture notes_5 '[{"id": 105, "system": false, "body": "Why?", "author": {"username": "anna"}}]'
run
check "note on an own MR: no events" "" "$out"
check "own MRs: no own MRs call" "" "$(grep 'own MRs call' "$d/err")"

fixture todos '[{"id": 13, "action_name": "mentioned", "author": {"username": "anna"},
  "target": {"iid": 5, "title": "Add foo", "source_branch": "ABC-1/foo",
    "author": {"username": "me"}},
  "target_url": "'"$url"'/5"}]'
run
check "to-do item on an own MR: no events" "" "$out"

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
  "watch-gitlab: user: dial tcp: connection refused" "$(cat "$d/err")"
unset MOCK_FAIL MOCK_FAIL_MSG

wt=$(printf %s "$d/app" | shasum | cut -c1-12)
sstate="$d/state/watch-gitlab/app-$wt.json"
gql() { # iid, jq filter that changes the default MR
  jq -n --arg iid "$1" --arg u "$url/$1" '{data: {currentUser: {username: "me"},
    project: {mergeRequest: ({iid: $iid, title: "Add foo", webUrl: $u, sourceBranch: "ABC-1/foo",
      state: "opened", author: {username: "me"}, mergeUser: null, headPipeline: null,
      approvedBy: {nodes: []}, detailedMergeStatus: "NOT_APPROVED", conflicts: false,
      mergeable: false, awardEmoji: {nodes: []}, discussions: {nodes: []}} | '"${2:-.}"')}}}' \
    >"$d/mock/gql_$1.json"
}
note() { # id author body [position]
  jq -nc --argjson id "$1" --arg a "$2" --arg b "$3" --arg u "$url/5#note_$1" \
    --argjson p "${4:-null}" \
    '{id: "gid://gitlab/DiffNote/\($id)", body: $b, system: false, url: $u,
      author: {username: $a}, position: $p, awardEmoji: {nodes: []}}'
}
thread() { # resolved, notes...
  local r=$1; shift
  jq -nc --argjson r "$r" '{resolvable: true, resolved: $r, notes: {nodes: $ARGS.positional}}' \
    --jsonargs "$@"
}
srun() { out=$(cd "$d/app" && "$script" --once "$@" 2>"$d/err"); code=$?; err=$(cat "$d/err"); }
sev() { # kind iid actor detail [url] [path line]
  jq -nc --arg k "$1" --argjson i "$2" --arg a "$3" --arg dt "$4" --arg u "${5:-$url/$2}" \
    --arg p "${6:-}" --arg l "${7:-}" \
    '{kind: $k, iid: $i, title: "Add foo", url: $u, actor: $a, detail: $dt, branch: "ABC-1/foo"}
     + if $p == "" then {} else {path: $p, line: ($l | tonumber)} end'
}
pos='{"newPath": "app/Foo.kt", "newLine": 42}'

reset_mock
gql 5
: >"$MOCK_LOG"
srun --mr 5
check "stack: first check: exit 0" 0 "$code"
check "stack: first check: no events" "" "$out"
check "stack: own state file" yes "$([ -f "$sstate" ] && echo yes || echo no)"
check "stack: no REST calls" "" "$(grep -v '^api graphql' "$MOCK_LOG" | grep '^api ')"
: >"$MOCK_LOG"

gql 5 '.headPipeline = {id: "gid://gitlab/Ci::Pipeline/50", status: "FAILED"}'
srun --mr 5
check "stack: pipeline failed" "$(sev pipeline 5 '' 'pipeline 50 failed')" "$out"
srun --mr 5
check "stack: same pipeline: no events" "" "$out"
gql 5 '.headPipeline = {id: "gid://gitlab/Ci::Pipeline/51", status: "RUNNING"}'
srun --mr 5
check "stack: running pipeline: no events" "" "$out"
gql 5 '.headPipeline = {id: "gid://gitlab/Ci::Pipeline/51", status: "SUCCESS"}'
srun --mr '!5'
check "stack: pipeline passed, iid with !" "$(sev pipeline 5 '' 'pipeline 51 passed')" "$out"

gql 5 '.approvedBy.nodes = [{username: "anna"}]'
srun --mr 5
check "stack: approved" "$(sev approved 5 anna approved)" "$out"
gql 5
srun --mr 5
check "stack: unapproved" "$(sev unapproved 5 anna 'approval removed')" "$out"

gql 5 '.conflicts = true | .detailedMergeStatus = "CONFLICT"'
srun --mr 5
check "stack: conflict" "$(sev conflict 5 '' 'merge conflict')" "$out"
gql 5 '.detailedMergeStatus = "CHECKING"'
srun --mr 5
check "stack: transient status: no events" "" "$out"
check "stack: transient status: old conflict value stays" true \
  "$(jq -r '.mrs["5"].conflicts' "$sstate")"
gql 5 '.detailedMergeStatus = "MERGEABLE" | .mergeable = true
  | .discussions.nodes = [{resolvable: true, resolved: false, notes: {nodes: []}}]'
srun --mr 5
check "stack: mergeable with open threads" "$(sev mergeable 5 '' 'now mergeable, 1 open thread(s)')" "$out"

reset_mock
gql 5 ".discussions.nodes = [$(thread false "$(note 100 anna old)")]"
srun --mr 5
check "stack: old comments of a new MR: no events" "" "$out"
gql 5 ".discussions.nodes = [$(thread false "$(note 100 anna old)" "$(note 101 anna 'Why
not X?' "$pos")")]"
srun --mr 5
check "stack: new comment and its thread" \
  "$(sev comment 5 anna 'Why not X?' "$url/5#note_101" app/Foo.kt 42)
$(sev unaddressed 5 anna 'Why not X?' "$url/5#note_101")" "$out"
gql 5 ".discussions.nodes = [$(thread false "$(note 100 anna old)" "$(note 101 anna 'Why
not X?' "$pos")" "$(note 102 me 'Because Y.')")]"
srun --mr 5
check "stack: own reply: no events" "" "$out"
gql 5 ".discussions.nodes = [$(thread true "$(note 103 bob 'Done?' "$pos")"),
  $(thread false "$(note 104 bob Typo "$pos")")]
  | .discussions.nodes[0].notes.nodes += [{id: \"gid://gitlab/Note/105\", body: \"added 1 commit\",
    system: true, url: \"x\", author: {username: \"anna\"}, position: null, awardEmoji: {nodes: []}}]"
srun --mr 5
check "stack: resolved thread and system note: no unaddressed line for them" \
  "$(sev comment 5 bob 'Done?' "$url/5#note_103" app/Foo.kt 42)
$(sev comment 5 bob Typo "$url/5#note_104" app/Foo.kt 42)
$(sev unaddressed 5 bob Typo "$url/5#note_104" app/Foo.kt 42)" "$out"

reset_mock
gql 5 ".discussions.nodes = [$(thread false "$(note 110 me 'See this' "$pos")")]"
srun --mr 5
gql 5 ".awardEmoji.nodes = [{name: \"thumbsup\", user: {username: \"bob\"}},
    {name: \"eyes\", user: {username: \"me\"}}]
  | .discussions.nodes = [$(thread false "$(note 110 me 'See this' "$pos")")]
  | .discussions.nodes[0].notes.nodes[0].awardEmoji.nodes = [{name: \"tada\", user: {username: \"anna\"}}]"
srun --mr 5
check "stack: reactions on the MR and on an own comment, not own reactions" \
  "$(sev reaction 5 bob ':thumbsup: on the MR')
$(sev reaction 5 anna ':tada: on your comment' "$url/5#note_110" app/Foo.kt 42)" "$out"
srun --mr 5
check "stack: same reactions: no events" "" "$out"

gql 5 '.state = "merged" | .mergeUser = {username: "anna"}'
srun --mr 5
check "stack: merged" "$(sev merged 5 anna merged)" "$out"
reset_mock
gql 5
srun --mr 5
gql 5 '.state = "closed"'
srun --mr 5
check "stack: closed" "$(sev closed 5 '' closed)" "$out"

reset_mock
gql 5
gql 6 '.iid = "6"'
srun --mr 5 --mr 6
gql 5 '.approvedBy.nodes = [{username: "anna"}]'
gql 6 '.iid = "6" | .approvedBy.nodes = [{username: "bob"}]'
srun --mr 6 --mr 5
check "stack: two MRs in the order of the options" \
  "$(sev approved 6 bob approved)
$(sev approved 5 anna approved)" "$out"

reset_mock
gql 5 ".discussions.nodes = [$(thread false "$(note 120 anna old)")]"
srun --mr 5
jq -n --argjson t "$(thread false "$(note 121 bob 'On page 2')")" \
  '{data: {currentUser: {username: "me"}, project: {mergeRequest: {discussions: {nodes: [$t]}}}}}' \
  >"$d/mock/gql_5_p2.json"
srun --mr 5
check "stack: comment on the second page of discussions" \
  "$(sev comment 5 bob 'On page 2' "$url/5#note_121")
$(sev unaddressed 5 anna old "$url/5#note_120")
$(sev unaddressed 5 bob 'On page 2' "$url/5#note_121")" "$out"

srun --mr 7
check "stack: unknown MR: exit 1" 1 "$code"
check "stack: unknown MR: message" "watch-gitlab: MR !7 not found in group/sub/app" "$err"
echo '{"errors": [{"message": "Field '"'"'awardEmoji'"'"' does not exist"}]}' >"$d/mock/gql_5.json"
srun --mr 5
check "stack: GraphQL error: exit 1" 1 "$code"
check "stack: GraphQL error: message" \
  "watch-gitlab: graphql: Field 'awardEmoji' does not exist" "$err"
: >"$MOCK_LOG"
out=$(cd "$d/app" && "$script" --mr 5 --interval 0 2>&1); code=$?
check "stack: GraphQL error: no new try" "1 1" "$code $(grep -c '^api graphql' "$MOCK_LOG")"
srun --mr x
check "stack: bad MR: message" "watch-gitlab: --mr needs an MR number" "$err"

gql 5
(cd "$d/app" && exec "$script" --interval 60 >/dev/null 2>"$d/hub.err") &
hub=$!
lock_is "$hub"
srun --mr 5
check "stack and hub: hub watch still runs" yes "$(ps -p "$hub" >/dev/null && echo yes || echo no)"
kill "$hub"; wait "$hub" 2>/dev/null

out=$("$script" --repo "$d/app" --once 2>&1); code=$?
check "--repo from a different folder: exit 0" 0 "$code"

reset_mock
gql 5
srun --mr 5
out=$(cd "$d/app" && "$script" --mr 5 --interval 0 --deadline 1 2>&1); code=$?
check "stack: deadline: exit 4" "4 watch-gitlab: deadline reached" "$code $out"

git init -q "$d/gone"
git -C "$d/gone" remote add origin https://gitlab.example.com/group/sub/app.git
(cd "$d/gone" && exec "$script" --interval 1 >/dev/null 2>"$d/gone.err") &
gone=$!
sleep 0.5
rm -rf "$d/gone"
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -p "$gone" >/dev/null || break; sleep 0.5; done
wait "$gone"
check "worktree gone: exit 1" 1 "$?"
check "worktree gone: message" "watch-gitlab: the worktree is gone: $d/gone" "$(cat "$d/gone.err")"

# The parent shell exits at once. The loop must stop after its next sleep.
(cd "$d/app" && bash -c '"$0" --interval 1 >/dev/null 2>"$1" & echo $! >"$2"; sleep 1' \
  "$script" "$d/orphan.err" "$d/orphan.pid")
orphan=$(cat "$d/orphan.pid")
for _ in 1 2 3 4 5 6 7 8 9 10; do ps -p "$orphan" >/dev/null || break; sleep 0.5; done
check "parent gone: process stops" no "$(ps -p "$orphan" >/dev/null && echo yes || echo no)"
check "parent gone: message" "watch-gitlab: the parent process is gone" \
  "$(cat "$d/orphan.err")"
kill "$orphan" 2>/dev/null

out=$("$script" --bogus 2>&1); code=$?
check "unexpected argument: exit 1" 1 "$code"
check "unexpected argument: message" "watch-gitlab: unexpected argument: --bogus" "$out"

exit $fail
