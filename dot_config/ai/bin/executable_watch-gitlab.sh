#!/usr/bin/env bash
# Usage: watch-gitlab.sh [--repo PATH] [--interval SECONDS] [--once] [--mr IID]...
# Stops at the first check with new events and prints one JSON line for each event: kind, iid,
# title, url, actor, detail, branch. With no state file, the first check only saves the state.
# --once: do one check, then stop.
# Hub mode (no --mr) watches to-do items, comments on MRs of other people, and the default
# branch. The default-failed event of the default branch has a null iid and title.
# Stack mode (--mr, one for each MR, `!` prefix allowed) watches these MRs: pipeline, comment,
# reaction, approved, unapproved, conflict, mergeable, merged, closed. Comments, reactions, and
# threads on a diff line also have path and line. After the events, it prints one unaddressed
# line for each open thread whose last comment is not from the user.
# A new instance stops an older instance of the same repo and mode. A stack watch has one
# instance for each worktree.
# Exit codes: 0 events found or --once done, 1 error, 3 a new instance replaced this one
set -euo pipefail

die() { echo "watch-gitlab: $1" >&2; exit 1; }

repo=$PWD
interval=120
once=0
mrs=()
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --interval) [[ $# -ge 2 ]] || die "--interval needs seconds"; interval=$2; shift 2 ;;
    --once) once=1; shift ;;
    --mr) [[ $# -ge 2 && ${2#!} =~ ^[0-9]+$ ]] || die "--mr needs an MR number"
      mrs+=("${2#!}"); shift 2 ;;
    *) die "unexpected argument: $1" ;;
  esac
done

command -v glab >/dev/null || die "glab is not installed"
command -v jq >/dev/null || die "jq is not installed"
cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"

state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/watch-gitlab
slug=$(~/.config/ai/bin/repo-slug.sh)
top=$(git rev-parse --show-toplevel)
key=$slug
# With the worktree hash in the key, the stack watch and the hub watch run at the same time.
((${#mrs[@]})) && key=$slug-$(printf %s "$top" | shasum | cut -c1-12)
state=$state_dir/$key.json
lock=$state_dir/$key.lock
mkdir -p "$state_dir"
# A new watch replaces the old one: stop an older instance of this script that holds the lock.
# The command check stops no different program that got the PID of a dead instance.
old=$(cat "$lock" 2>/dev/null || true)
if [[ -n $old ]] && ps -o command= -p "$old" 2>/dev/null | grep -q 'watch-gitlab\.sh'; then
  kill "$old" 2>/dev/null || true
  for _ in {1..20}; do ps -p "$old" >/dev/null || break; sleep 0.5; done
  kill -KILL "$old" 2>/dev/null || true
fi
glab auth status >/dev/null 2>&1 || die "glab is not authenticated, run: glab auth login"
tmp=$(mktemp -d)
echo $$ >"$lock"
sleeper=''
cleanup() {
  if [[ -n $sleeper ]]; then kill "$sleeper" 2>/dev/null || true; fi
  rm -rf "$tmp"
  if [[ $(cat "$lock" 2>/dev/null) == "$$" ]]; then rm -f "$lock"; fi
}
trap cleanup EXIT
trap 'echo "watch-gitlab: replaced by a new watch" >&2; exit 3' TERM

# The parent of this script can be a wrapper shell that stays alive after the agent is killed,
# so the check covers all ancestors. `ps`, not `kill -0`: `kill -0` fails on processes of root.
ancestors=()
p=$PPID
while ((p > 1)); do ancestors+=("$p"); p=$(ps -o ppid= -p "$p" | tr -d ' '); done
parent_gone() {
  local p
  for p in "${ancestors[@]}"; do ps -p "$p" >/dev/null || return 0; done
  return 1
}

remote=$(git remote get-url origin 2>/dev/null \
  || git remote get-url "$(git remote | head -n1)" 2>/dev/null) || die "no git remote in $repo"
project=$(sed -E 's#\.git$##; s#^[a-z+]+://[^/]+/##; s#^[^@/]+@[^:]+:##' <<<"$remote")

permission_for() {
  case "$1" in
    user) echo 'User (user boundary)' ;;
    users/*/events*) echo 'Event (user boundary)' ;;
    todos*) echo 'Todo (user boundary)' ;;
    projects/*/merge_requests/*/notes*) echo 'Work Item (group or project boundary)' ;;
    projects/*/merge_requests*) echo 'Merge Request (group or project boundary)' ;;
    projects/*/pipelines*) echo 'Pipeline (group or project boundary)' ;;
    graphql) echo 'Merge Request (group or project boundary)' ;;
    *) echo 'Project (group or project boundary)' ;;
  esac
}

http_re='HTTP (401|403)'

# On an error: returns 2 for HTTP 401 or 403, else 1, with the message in $tmp/error.
api() {
  if glab api "$@" 2>"$tmp/stderr"; then return 0; fi
  local err
  err=$(paste -s -d ' ' "$tmp/stderr")
  if [[ $err =~ $http_re ]]; then
    echo "HTTP ${BASH_REMATCH[1]} on $1." \
      "The token needs the Read permission for $(permission_for "$1")." >"$tmp/error"
    return 2
  fi
  echo "$1: $err" >"$tmp/error"
  return 1
}

MR_QUERY='query($path: ID!, $iid: String!, $endCursor: String) {
  currentUser { username }
  project(fullPath: $path) { mergeRequest(iid: $iid) {
    iid title webUrl sourceBranch state
    mergeUser { username }
    headPipeline { id status }
    approvedBy { nodes { username } }
    detailedMergeStatus conflicts mergeable
    awardEmoji { nodes { name user { username } } }
    discussions(first: 100, after: $endCursor) { pageInfo { hasNextPage endCursor }
      nodes { resolvable resolved
      notes(first: 100) { nodes { id body system url author { username }
        position { newPath newLine }
        awardEmoji { nodes { name user { username } } } } } } }
  } }
}'

# glab --paginate prints one JSON document for each page. On a GraphQL error, glab exits 1 and
# prints the body. It returns 2, because a new try gives the same error.
gql() {
  local rc=0
  api graphql --paginate -f query="$MR_QUERY" -f path="$project" -f iid="$1" >"$tmp/gql.json" \
    || rc=$?
  if jq -se 'any(.[]; .errors)' "$tmp/gql.json" >/dev/null 2>&1; then
    echo "graphql: $(jq -rs '[.[].errors[]?.message] | join("; ")' "$tmp/gql.json")" \
      >"$tmp/error"
    return 2
  fi
  ((rc == 0)) || return "$rc"
  if jq -se '.[0].data.project.mergeRequest == null' "$tmp/gql.json" >/dev/null; then
    echo "MR !$1 not found in $project" >"$tmp/error"
    return 2
  fi
  jq -cs '[.[].data.project.mergeRequest.discussions.nodes[]] as $all
    | .[0].data | .project.mergeRequest.discussions.nodes = $all' "$tmp/gql.json"
}

pid=''

PROGRAM=$(cat <<'JQ'
def by_iid: map({key: (.iid | tostring), value: .}) | from_entries;

$old[0] as $old | $todos[0] as $todos
| ($watched[0] | map(select(.author.username != $me)) | by_iid) as $by
| ($notes | map({key: (.iid | tostring), value: .notes}) | from_entries) as $notes_by
| ($default[0][0] | if . then {id, status} else null end) as $default_pipeline
| ($by | with_entries(.key as $k | ($old.mrs[$k] // {}) as $o | .value |= {
    updated_at,
    last_note_id: ([($notes_by[$k] // [])[].id, $o.last_note_id // 0] | max)
  })) as $mrs
| {
    state: {todos: [$todos[].id], mrs: $mrs, default_pipeline: $default_pipeline},
    events: (if $old == null then [] else [
      ($todos[] | select(.id as $id | $old.todos | any(. == $id) | not)
        | select(.target.author.username != $me)
        | {kind: "todo", iid: .target.iid, title: .target.title, url: .target_url,
           actor: .author.username, detail: .action_name, branch: .target.source_branch}),
      ($default[0][0] | select($old | has("default_pipeline"))
        | select(. != null and .id != $old.default_pipeline.id and .status == "failed")
        | {kind: "default-failed", iid: null, title: null, url: .web_url, actor: "",
           detail: "pipeline \(.id) failed", branch: $default_branch}),
      ($by | to_entries[] | .key as $k | .value as $mr | $old.mrs[$k] as $o
        | select($o != null)
        | ($notes_by[$k] // [])[]
        | select(.id > $o.last_note_id and (.system | not) and .author.username != $me)
        | {kind: "note", iid: $mr.iid, title: $mr.title, url: "\($mr.web_url)#note_\(.id)",
           actor: .author.username, detail: (.body | gsub("\\s+"; " ") | .[0:100]),
           branch: $mr.source_branch})
    ] end)
  }
JQ
)

STACK_PROGRAM=$(cat <<'JQ'
def num: split("/") | last | tonumber;
def short: gsub("\\s+"; " ") | .[0:100];
def at($p): if $p.newPath then {path: $p.newPath, line: $p.newLine} else {} end;
def event($kind; $mr; $actor; $detail; $url):
  {kind: $kind, iid: $mr.iid, title: $mr.title, url: ($url // $mr.url), actor: $actor,
   detail: $detail, branch: $mr.branch};
# GitLab computes the merge status async. A transient status keeps the last stable values.
def transient: IN("checking", "unchecked", "preparing", "approvals_syncing");
def norm($me):
  [.discussions.nodes[] | {resolvable, resolved,
     notes: [.notes.nodes[] | select(.system | not) | .id |= num]}] as $ds
  | {
      iid: (.iid | tonumber), title, url: .webUrl, branch: .sourceBranch, state,
      merge_user: (.mergeUser.username // ""),
      pipeline: (.headPipeline
        | if . then {id: (.id | num), status: (.status | ascii_downcase)} else null end),
      approved_by: [.approvedBy.nodes[].username],
      merge_status: ((.detailedMergeStatus // "") | ascii_downcase),
      conflicts, mergeable,
      notes: [$ds[].notes[]],
      reactions: (
        [.awardEmoji.nodes[] | {key: "mr:\(.name):\(.user.username)", name,
          user: .user.username, on: null, url: null, position: null}]
        + [$ds[].notes[] | . as $n | .awardEmoji.nodes[]
          | {key: "\($n.id):\(.name):\(.user.username)", name, user: .user.username,
             on: $n.author.username, url: $n.url, position: $n.position}]),
      open_threads: ([$ds[] | select(.resolvable and (.resolved | not))] | length),
      unaddressed: [$ds[] | select(.resolvable and (.resolved | not)) | .notes
        | select(length > 0 and .[-1].author.username != $me)
        | {last: .[-1], position: .[0].position}]
    };

($data[0].currentUser.username) as $me
| $old[0] as $old
| [$data[].project.mergeRequest | norm($me)] as $now
| ($now | map({key: (.iid | tostring), value: (. as $n | ($old.mrs[.iid | tostring] // {}) as $o
    | {state, pipeline, approved_by,
       conflicts: (if $n.merge_status | transient then $o.conflicts else $n.conflicts end),
       mergeable: (if $n.merge_status | transient then $o.mergeable else $n.mergeable end),
       last_note_id: ([$n.notes[].id, $o.last_note_id // 0] | max),
       reactions: [$n.reactions[].key]})}) | from_entries) as $mrs
| [$now[] as $mr | ($old.mrs // {})[$mr.iid | tostring] as $o | $mrs[$mr.iid | tostring] as $n
    | select($o != null)
    | (($mr.notes[] | select(.id > $o.last_note_id and .author.username != $me)
         | event("comment"; $mr; .author.username; (.body | short); .url) + at(.position)),
       ($mr.reactions[] | select(.user != $me) | select(.key as $k | $o.reactions | index($k) | not)
         | event("reaction"; $mr; .user;
             ":\(.name): on " + (if .on == null then "the MR" elif .on == $me then "your comment"
               else "a comment of @\(.on)" end); .url) + at(.position)),
       (select($n.pipeline != $o.pipeline and ($n.pipeline.status | IN("failed", "success")))
         | event("pipeline"; $mr; "";
             "pipeline \($n.pipeline.id) \(if $n.pipeline.status == "success" then "passed"
               else "failed" end)"; null)),
       (($n.approved_by - $o.approved_by)[] | event("approved"; $mr; .; "approved"; null)),
       (($o.approved_by - $n.approved_by)[]
         | event("unapproved"; $mr; .; "approval removed"; null)),
       (select($n.conflicts and ($o.conflicts | not))
         | event("conflict"; $mr; ""; "merge conflict"; null)),
       (select($n.mergeable and ($o.mergeable | not))
         | event("mergeable"; $mr; "";
             "now mergeable, \($mr.open_threads) open thread(s)"; null)),
       (select($o.state == "opened" and $n.state == "merged")
         | event("merged"; $mr; $mr.merge_user; "merged"; null)),
       (select($o.state == "opened" and $n.state == "closed")
         | event("closed"; $mr; ""; "closed"; null)))
  ] as $events
| {
    state: {mrs: $mrs},
    events: (if $events == [] then [] else $events + [$now[] as $mr | $mr.unaddressed[]
      | event("unaddressed"; $mr; .last.author.username; (.last.body | short); .last.url)
        + at(.position)] end)
  }
JQ
)

check_stack() {
  local old=$state iid
  [[ -f $old ]] || old=/dev/null
  : >"$tmp/mrs.jsonl"
  for iid in "${mrs[@]}"; do
    gql "$iid" >>"$tmp/mrs.jsonl" || return
  done
  jq -n --slurpfile old "$old" --slurpfile data "$tmp/mrs.jsonl" "$STACK_PROGRAM" \
    >"$tmp/result.json" || { echo "jq could not compare the state" >"$tmp/error"; return 1; }
  jq '.state' "$tmp/result.json" >"$state.tmp" && mv "$state.tmp" "$state"
  jq -c '.events[]' "$tmp/result.json"
}

check_mode() { if ((${#mrs[@]})); then check_stack; else check; fi; }

check() {
  local old=$state since iids iid user project_json
  if [[ -z $pid ]]; then
    user=$(api user) || return
    project_json=$(api "projects/$(jq -rn --arg p "$project" '$p | @uri')") || return
    me_id=$(jq -r .id <<<"$user")
    me=$(jq -r .username <<<"$user")
    pid=$(jq -r .id <<<"$project_json")
    default_branch=$(jq -r .default_branch <<<"$project_json")
    default_ref=$(jq -r '.default_branch | @uri' <<<"$project_json")
  fi
  [[ -f $old ]] || old=/dev/null
  since=$(jq -nr 'now | floor - 14 * 86400 | todate')
  api "todos?project_id=$pid&type=MergeRequest&state=pending&per_page=100" >"$tmp/todos.json" \
    || return
  api "users/$me_id/events?target_type=note&after=${since%%T*}&per_page=100" \
    >"$tmp/events.json" || return
  iids=$(jq -r --argjson pid "$pid" '[.[] | select(.project_id == $pid
      and .note.noteable_type == "MergeRequest") | "iids[]=\(.note.noteable_iid)"]
    | unique | join("&")' "$tmp/events.json")
  echo '[]' >"$tmp/commented.json"
  if [[ -n $iids ]]; then
    api "projects/$pid/merge_requests?state=all&$iids&per_page=100" >"$tmp/commented.json" \
      || return
  fi
  cp "$tmp/commented.json" "$tmp/watched.json"
  # Only MRs with a changed updated_at get a notes call: a new note changes updated_at.
  : >"$tmp/notes.jsonl"
  for iid in $(jq -r --slurpfile old "$old" \
      '.[] | select($old[0].mrs[.iid | tostring].updated_at != .updated_at) | .iid' \
      "$tmp/watched.json"); do
    api "projects/$pid/merge_requests/$iid/notes?sort=desc&order_by=created_at&per_page=50" \
      >"$tmp/notes.json" || return
    jq -c --argjson iid "$iid" '{iid: $iid, notes: .}' "$tmp/notes.json" >>"$tmp/notes.jsonl"
  done
  api "projects/$pid/pipelines?ref=$default_ref&scope=finished&per_page=1" >"$tmp/default.json" \
    || return
  jq -n --slurpfile old "$old" --slurpfile todos "$tmp/todos.json" \
      --slurpfile watched "$tmp/watched.json" --slurpfile notes "$tmp/notes.jsonl" \
      --slurpfile default "$tmp/default.json" \
      --arg me "$me" --arg default_branch "$default_branch" "$PROGRAM" >"$tmp/result.json" \
    || { echo "jq could not compare the state" >"$tmp/error"; return 1; }
  jq '.state' "$tmp/result.json" >"$state.tmp" && mv "$state.tmp" "$state"
  jq -c '.events[]' "$tmp/result.json"
}

fails=0
while :; do
  if check_mode >"$tmp/events"; then
    fails=0
    if [[ -s $tmp/events || $once == 1 ]]; then cat "$tmp/events"; exit 0; fi
  else
    rc=$?
    [[ $rc == 2 ]] && die "$(cat "$tmp/error")"
    fails=$((fails + 1))
    [[ $once == 1 || $fails -ge 5 ]] && die "$(cat "$tmp/error")"
  fi
  # In the background: bash runs the TERM trap only after a foreground command ends.
  sleep "$interval" &
  sleeper=$!
  wait "$sleeper"
  sleeper=''
  parent_gone && die "the parent process is gone"
done
