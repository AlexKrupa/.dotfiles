#!/usr/bin/env bash
# Usage: hub-watch-gitlab.sh [--repo PATH] [--interval SECONDS] [--once]
# Stops at the first check with new GitLab MR events and prints one JSON line for each event:
# kind, iid, title, url, actor, detail, branch. With no state file, the first check only saves the
# state. --once: do one check, then stop.
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

scope_for() {
  case "$1" in
    user | users/*) echo read_user ;;
    *) echo read_api ;;
  esac
}

http_re='HTTP (401|403)'

# On an error: returns 2 for HTTP 401 or 403, else 1, with the message in $tmp/error.
api() {
  if glab api "$1" 2>"$tmp/stderr"; then return 0; fi
  local err
  err=$(paste -s -d ' ' "$tmp/stderr")
  if [[ $err =~ $http_re ]]; then
    echo "HTTP ${BASH_REMATCH[1]} on $1. The token needs the $(scope_for "$1") scope." \
      >"$tmp/error"
    return 2
  fi
  echo "$1: $err" >"$tmp/error"
  return 1
}

pid=''

# Inputs: $old (the slurped state file, empty at the first check), $todos (the slurped To-Do
# list), $watched (the slurped list of watched MRs), $notes (one {iid, notes} object for each MR
# with fetched notes), and $me. Output: {state, events}.
PROGRAM=$(cat <<'JQ'
def by_iid: map({key: (.iid | tostring), value: .}) | from_entries;
def event($kind; $mr; $actor; $detail; $url):
  {kind: $kind, iid: $mr.iid, title: $mr.title, url: $url, actor: $actor, detail: $detail,
   branch: $mr.source_branch};

$old[0] as $old | $todos[0] as $todos | ($watched[0] | by_iid) as $by
| ($notes | map({key: (.iid | tostring), value: .notes}) | from_entries) as $notes_by
| ($by | with_entries(.key as $k | ($old.mrs[$k] // {}) as $o | .value |= {
    updated_at, state,
    last_note_id: ([($notes_by[$k] // [])[].id, $o.last_note_id // 0] | max)
  })) as $mrs
| {
    state: {todos: [$todos[].id], mrs: $mrs},
    events: (if $old == null then [] else [
      ($todos[] | select(.id as $id | $old.todos | any(. == $id) | not)
        | {kind: "todo", iid: .target.iid, title: .target.title, url: .target_url,
           actor: .author.username, detail: .action_name, branch: .target.source_branch}),
      ($by | to_entries[] | .key as $k | .value as $mr | $old.mrs[$k] as $o
        | select($o != null)
        | ($notes_by[$k] // [])[]
        | select(.id > $o.last_note_id and (.system | not) and .author.username != $me)
        | event("note"; $mr; .author.username; (.body | gsub("\\s+"; " ") | .[0:100]);
            "\($mr.web_url)#note_\(.id)"))
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
  jq -n --slurpfile old "$old" --slurpfile todos "$tmp/todos.json" \
      --slurpfile watched "$tmp/watched.json" --slurpfile notes "$tmp/notes.jsonl" \
      --arg me "$me" "$PROGRAM" >"$tmp/result.json" \
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
