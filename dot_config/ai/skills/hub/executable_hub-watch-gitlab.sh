#!/usr/bin/env bash
# Usage: hub-watch-gitlab.sh [--repo PATH] [--interval SECONDS] [--once]
# Stops at the first check with new GitLab MR events and prints one JSON line for each event:
# kind, iid, title, url, actor, detail, branch. The default-failed event of the default branch has
# a null iid and title. With no state file, the first check only saves the state. --once: do one
# check, then stop.
# Exit codes: 0 events found or --once done, 1 error
set -euo pipefail

die() { echo "hub-watch-gitlab: $1" >&2; exit 1; }

repo=$PWD
interval=120
once=0
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --interval) [[ $# -ge 2 ]] || die "--interval needs seconds"; interval=$2; shift 2 ;;
    --once) once=1; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done

command -v glab >/dev/null || die "glab is not installed"
command -v jq >/dev/null || die "jq is not installed"
cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"

state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/hub
slug=$(~/.config/ai/bin/repo-slug.sh)
state=$state_dir/$slug.json
lock=$state_dir/$slug.lock
mkdir -p "$state_dir"
if [[ -f $lock ]] && kill -0 "$(cat "$lock")" 2>/dev/null; then
  die "hub watch already runs for this repo (PID $(cat "$lock"))"
fi
glab auth status >/dev/null 2>&1 || die "glab is not authenticated, run: glab auth login"
tmp=$(mktemp -d)
echo $$ >"$lock"
trap 'rm -rf "$tmp" "$lock"' EXIT

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
    *) echo 'Project (group or project boundary)' ;;
  esac
}

http_re='HTTP (401|403)'

# On an error: returns 2 for HTTP 401 or 403, else 1, with the message in $tmp/error.
api() {
  if glab api "$1" 2>"$tmp/stderr"; then return 0; fi
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

pid=''

PROGRAM=$(cat <<'JQ'
def by_iid: map({key: (.iid | tostring), value: .}) | from_entries;
def event($kind; $mr; $actor; $detail; $url):
  {kind: $kind, iid: $mr.iid, title: $mr.title, url: $url, actor: $actor, detail: $detail,
   branch: $mr.source_branch};

$old[0] as $old | $todos[0] as $todos | ($watched[0] | by_iid) as $by
| ($open | by_iid) as $open_by
| ($notes | map({key: (.iid | tostring), value: .notes}) | from_entries) as $notes_by
| ($default[0][0] | if . then {id, status} else null end) as $default_pipeline
| ($by | with_entries(.key as $k | ($old.mrs[$k] // {}) as $o | .value |= {
    updated_at, state,
    last_note_id: ([($notes_by[$k] // [])[].id, $o.last_note_id // 0] | max),
    pipeline: $open_by[$k].pipeline,
    approved_by: ($open_by[$k].approved_by // []),
    # GitLab computes the merge status async: a transient status keeps the last stable status.
    merge_status: ($open_by[$k].merge_status
      | if . == null or IN("checking", "unchecked", "preparing", "approvals_syncing")
        then $o.merge_status else . end)
  })) as $mrs
| {
    state: {todos: [$todos[].id], mrs: $mrs, default_pipeline: $default_pipeline},
    events: (if $old == null then [] else [
      ($todos[] | select(.id as $id | $old.todos | any(. == $id) | not)
        | {kind: "todo", iid: .target.iid, title: .target.title, url: .target_url,
           actor: .author.username, detail: .action_name, branch: .target.source_branch}),
      ($default[0][0] | select($old | has("default_pipeline"))
        | select(. != null and .id != $old.default_pipeline.id and .status == "failed")
        | {kind: "default-failed", iid: null, title: null, url: .web_url, actor: "",
           detail: "pipeline \(.id) failed", branch: $default_branch}),
      ($by | to_entries[] | .key as $k | .value as $mr | $old.mrs[$k] as $o | $mrs[$k] as $n
        | select($o != null)
        | ((($notes_by[$k] // [])[]
             | select(.id > $o.last_note_id and (.system | not) and .author.username != $me)
             | event("note"; $mr; .author.username; (.body | gsub("\\s+"; " ") | .[0:100]);
                 "\($mr.web_url)#note_\(.id)")),
           (select($mr.author.username == $me and $mr.state == "opened")
             | ($n.pipeline != $o.pipeline) as $new_pipeline
             | ($new_pipeline and $n.pipeline.status == "success") as $passed
             | ($n.approved_by - ($o.approved_by // [])) as $added
             | (($o | has("merge_status")) and $n.merge_status != $o.merge_status) as $merge_changed
             | ($merge_changed and $n.merge_status == "mergeable") as $mergeable
             | (select($new_pipeline and $n.pipeline.status == "failed")
                 | event("pipeline"; $mr; ""; "pipeline \($n.pipeline.id) failed"; $mr.web_url)),
               # A new mergeable status holds the approvals and the passed pipeline of this check.
               (select($mergeable | not)
                 | (select($passed)
                     | event("pipeline"; $mr; ""; "pipeline \($n.pipeline.id) passed";
                         $mr.web_url)),
                   ($added[] | event("approved"; $mr; .; "approved"; $mr.web_url))),
               (select($mergeable)
                 | event("mergeable"; $mr; $added[0] // "";
                     [(select($added != []) | "approved by \($added | map("@" + .) | join(", "))"),
                      (select($passed) | "pipeline \($n.pipeline.id) passed"), "now mergeable"]
                     | join(", "); $mr.web_url)),
               (select($merge_changed and ($n.merge_status | IN("conflict", "need_rebase")))
                 | event("conflict"; $mr; "";
                     if $n.merge_status == "conflict" then "merge conflict" else "needs rebase" end;
                     $mr.web_url)),
               ((($o.approved_by // []) - $n.approved_by)[]
                 | event("unapproved"; $mr; .; "approval removed"; $mr.web_url))),
           (select($mr.author.username == $me and $o.state == "opened"
               and ($mr.state == "merged" or $mr.state == "closed"))
             | ((if $mr.state == "merged" then $mr.merge_user // $mr.merged_by
                 else $mr.closed_by end) | .username // "") as $actor
             | select($actor != $me)
             | event($mr.state; $mr; $actor; $mr.state; $mr.web_url))))
    ] end)
  }
JQ
)

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
  api "projects/$pid/merge_requests?author_username=$me&state=all&updated_after=$since&per_page=100" \
    >"$tmp/mine.json" || return
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
  jq -s 'add | unique_by(.iid)' "$tmp/mine.json" "$tmp/commented.json" >"$tmp/watched.json"
  # Only MRs with a changed updated_at get a notes call: a new note changes updated_at.
  : >"$tmp/notes.jsonl"
  for iid in $(jq -r --slurpfile old "$old" \
      '.[] | select($old[0].mrs[.iid | tostring].updated_at != .updated_at) | .iid' \
      "$tmp/watched.json"); do
    api "projects/$pid/merge_requests/$iid/notes?sort=desc&order_by=created_at&per_page=50" \
      >"$tmp/notes.json" || return
    jq -c --argjson iid "$iid" '{iid: $iid, notes: .}' "$tmp/notes.json" >>"$tmp/notes.jsonl"
  done
  # Pipeline and approval changes do not change updated_at.
  : >"$tmp/open.jsonl"
  for iid in $(jq -r '.[] | select(.state == "opened") | .iid' "$tmp/mine.json"); do
    api "projects/$pid/merge_requests/$iid" >"$tmp/mr.json" || return
    api "projects/$pid/merge_requests/$iid/approvals" >"$tmp/approvals.json" || return
    jq -c --argjson iid "$iid" --slurpfile a "$tmp/approvals.json" \
      '{iid: $iid, pipeline: (.head_pipeline | if . then {id, status} else null end),
        approved_by: [$a[0].approved_by[].user.username], merge_status: .detailed_merge_status}' \
      "$tmp/mr.json" >>"$tmp/open.jsonl"
  done
  api "projects/$pid/pipelines?ref=$default_ref&scope=finished&per_page=1" >"$tmp/default.json" \
    || return
  jq -n --slurpfile old "$old" --slurpfile todos "$tmp/todos.json" \
      --slurpfile watched "$tmp/watched.json" --slurpfile notes "$tmp/notes.jsonl" \
      --slurpfile open "$tmp/open.jsonl" --slurpfile default "$tmp/default.json" \
      --arg me "$me" --arg default_branch "$default_branch" "$PROGRAM" >"$tmp/result.json" \
    || { echo "jq could not compare the state" >"$tmp/error"; return 1; }
  jq '.state' "$tmp/result.json" >"$state.tmp" && mv "$state.tmp" "$state"
  jq -c '.events[]' "$tmp/result.json"
}

fails=0
while :; do
  if check >"$tmp/events"; then
    fails=0
    if [[ -s $tmp/events || $once == 1 ]]; then cat "$tmp/events"; exit 0; fi
  else
    rc=$?
    [[ $rc == 2 ]] && die "$(cat "$tmp/error")"
    fails=$((fails + 1))
    [[ $once == 1 || $fails -ge 5 ]] && die "$(cat "$tmp/error")"
  fi
  sleep "$interval"
done
