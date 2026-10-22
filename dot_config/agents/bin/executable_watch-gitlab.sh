#!/usr/bin/env bash
# Usage: watch-gitlab.sh [--repo PATH] [--fresh] [--review] [--mr IID]... [--skip-mr IID]...
# The check engine of the watch daemon watchd.sh. It does one check and prints one JSON line for
# each new event: kind, iid, title, url, actor, detail, branch. With no state file, the check only
# saves the state. A value that the saved state does not have gives no event at its first check.
# --fresh: delete the state file before the check.
# --skip-mr: hub mode, an MR with a review watch.
# WATCH_MR_CACHE=DIR: a fetched MR goes to DIR/<iid>.json, and a later fetch of the MR reads it.
#
# Hub mode (no --mr) watches the project of the repo, for the hub. Events:
#   kind            when                                          except
#   todo            a new pending to-do item on an MR             on an MR of the user
#   opened          a new open MR, of the newest 100              an MR of the user
#   note            a new comment on an MR of a different         a comment of the user, a system
#                   person that the user commented on (14 days)   note
#   reaction        a new reaction on a comment of the user       a reaction of the user
#   default-failed  a new failed default-branch pipeline          a pipeline id below the saved id,
#                                                                 for example during a job retry
# An MR of --skip-mr gives only the review_requested to-do item and the opened event. The agent of
# the review watch reports the other events.
# opened: actor is the MR author. default-failed: iid and title are null, and previous is the
# status of the saved default-branch pipeline, or null.
#
# Stack mode (--mr, one for each MR, `!` prefix allowed) watches the MRs of the stack of the user.
# Review mode (--review and one --mr) watches one MR for its reviewer. Events of both modes:
#   kind                     when                                       except
#   pipeline                 the head pipeline failed or passed
#   comment                  a new comment                              a comment of the user
#   own-comment              a new comment of the user
#   reaction                 a new reaction, on the MR or a comment     a reaction of the user
#   approved, unapproved     an approval added or removed               the user
#   draft, ready             the draft state changed                    a change of the user
#   title                    the title changed (detail: new title)      a change of the user
#   description              the description changed                    a change of the user
#   labels                   the labels changed (detail: +new, -gone)   a change of the user
#   conflict                 a merge conflict started
#   mergeable                the MR became mergeable
#   merged, closed           the MR was merged or closed                none (the user: own true)
#   unaddressed              after the other events: each open thread   a thread that the user
#                            whose last comment is not of the user      answered last
# Review mode only:
#   pushed                   the head changed (old_base, old_head, new_base, new_head)
#   resolved                 a different user resolved a thread that the user started
#   unaddressed              only for the threads that have a comment of the user
# Comments, reactions, and threads on a diff line also have path and line. The actor of a change
# comes from the newest system note of that change, or is empty.
#
# A stack watch has its own state for each worktree. A review watch has its own state for each MR.
# Exit codes: 0 check done, 1 error, 4 network error, 5 permanent error (HTTP 401 or 403, a
# GraphQL error, an unknown MR, unreadable comments, no glab authentication).
set -euo pipefail

die() { echo "watch-gitlab: $1" >&2; exit 1; }
# shellcheck source=watch-lib.sh
source "$HOME/.config/agents/bin/watch-lib.sh"
# shellcheck source=watch-state.sh
source "$HOME/.config/agents/bin/watch-state.sh"

repo=$PWD
mrs=()
skip_mrs=()
review=0
fresh=0
while (($#)); do
  case "$1" in
    --repo) [[ $# -ge 2 ]] || die "--repo needs a path"; repo=$2; shift 2 ;;
    --mr) [[ $# -ge 2 && ${2#!} =~ ^[0-9]+$ ]] || die "--mr needs an MR number"
      mrs+=("${2#!}"); shift 2 ;;
    --skip-mr) [[ $# -ge 2 && ${2#!} =~ ^[0-9]+$ ]] || die "--skip-mr needs an MR number"
      skip_mrs+=("${2#!}"); shift 2 ;;
    --review) review=1; shift ;;
    --fresh) fresh=1; shift ;;
    *) die "unexpected argument: $1" ;;
  esac
done
if ((review)) && ((${#mrs[@]} != 1)); then die "--review needs exactly one --mr"; fi

command -v glab >/dev/null || die "glab is not installed"
command -v jq >/dev/null || die "jq is not installed"
cd "$repo" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"

state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/watch-gitlab
key=$(watch_key "$PWD" "$review" ${mrs[@]+"${mrs[@]}"})
state=$state_dir/$key.json
mkdir -p "$state_dir"
if ! glab auth status >/dev/null 2>&1; then
  echo "watch-gitlab: glab is not authenticated, run: glab auth login" >&2
  exit 5
fi
tmp=$(mktemp -d)
((fresh)) && rm -f "$state"
trap 'rm -rf "$tmp"' EXIT

remote=$(git remote get-url origin 2>/dev/null \
  || git remote get-url "$(git remote | head -n1)" 2>/dev/null) || die "no git remote in $repo"
project=$(sed -E 's#\.git$##; s#^[a-z+]+://[^/]+/##; s#^[^@/]+@[^:]+:##' <<<"$remote")
project_ref=$(jq -rn --arg p "$project" '$p | @uri')

permission_for() {
  case "$1" in
    user) echo 'User (user boundary)' ;;
    users/*/events*) echo 'Event (user boundary)' ;;
    todos*) echo 'Todo (user boundary)' ;;
    projects/*/merge_requests/*/notes*) echo 'Work Item (group or project boundary)' ;;
    projects/*/merge_requests/*/discussions*) echo 'Work Item (group or project boundary)' ;;
    projects/*/merge_requests*) echo 'Merge Request (group or project boundary)' ;;
    projects/*/pipelines*) echo 'Pipeline (group or project boundary)' ;;
    graphql) echo 'Merge Request (group or project boundary)' ;;
    *) echo 'Project (group or project boundary)' ;;
  esac
}

http_re='HTTP (401|403)'

# On an error: returns 2 for HTTP 401 or 403, 3 for a network error, else 1, with the message in
# $tmp/error.
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
  is_network_error "$err" && return 3
  return 1
}

MR_QUERY='query($path: ID!, $iid: String!) {
  currentUser { username }
  project(fullPath: $path) { mergeRequest(iid: $iid) {
    iid title webUrl sourceBranch state draft
    mergeUser { username }
    headPipeline { id status }
    approvedBy { nodes { username } }
    detailedMergeStatus conflicts mergeable
  } }
}'

# With a fine-grained token, GraphQL gives no discussions, diff refs, or reactions, and no error.
# They come from REST, in the form of the GraphQL fields.
# On a GraphQL error, glab exits 1 and prints the body. It returns 2, because a new try gives
# the same error.
fetch_mr() {
  local rc=0 mr_path count note_id
  if [[ -n ${WATCH_MR_CACHE:-} && -f $WATCH_MR_CACHE/$1.json ]]; then
    cat "$WATCH_MR_CACHE/$1.json"
    return
  fi
  api graphql -f query="$MR_QUERY" -f path="$project" -f iid="$1" >"$tmp/gql.json" || rc=$?
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
  mr_path=projects/$project_ref/merge_requests/$1
  api "$mr_path" >"$tmp/mr.json" || return
  api "$mr_path/discussions?per_page=100" --paginate >"$tmp/pages.json" || return
  # glab can print one array for each page.
  jq -s 'add // []' "$tmp/pages.json" >"$tmp/discussions.json"
  count=$(jq '.user_notes_count // 0' "$tmp/mr.json")
  if ((count > 0)) && jq -e 'all(.[].notes[]; .system)' "$tmp/discussions.json" >/dev/null; then
    echo "MR !$1 has $count comment(s), but $mr_path/discussions?per_page=100 gave none." \
      "The token needs the Read permission for $(permission_for "$mr_path/discussions")." \
      >"$tmp/error"
    return 2
  fi
  api "$mr_path/award_emoji?per_page=100" >"$tmp/mr_emoji.json" || return
  : >"$tmp/note_emoji.jsonl"
  for note_id in $(jq '.[].notes[] | select(.system | not) | .id' "$tmp/discussions.json"); do
    api "$mr_path/notes/$note_id/award_emoji?per_page=100" >"$tmp/emoji.json" || return
    jq -c --arg id "$note_id" '{($id): .}' "$tmp/emoji.json" >>"$tmp/note_emoji.jsonl"
  done
  jq -c --slurpfile mr "$tmp/mr.json" --slurpfile discussions "$tmp/discussions.json" \
    --slurpfile mr_emoji "$tmp/mr_emoji.json" --slurpfile note_emoji "$tmp/note_emoji.jsonl" '
    def emoji: {nodes: [.[] | {name, user: {username: .user.username}}]};
    ($note_emoji | add // {}) as $emoji_by_note
    | .data | .project.mergeRequest.webUrl as $url
    | .project.mergeRequest += {
        description: ($mr[0].description // ""), labels: ($mr[0].labels // []),
        diffRefs: ($mr[0].diff_refs
          | if . then {baseSha: .base_sha, headSha: .head_sha} else null end),
        awardEmoji: ($mr_emoji[0] | emoji),
        discussions: {nodes: [$discussions[0][] | [.notes[] | select(.resolvable)] as $resolvable
          | {id, resolvable: ($resolvable != []),
             resolved: ($resolvable != [] and all($resolvable[]; .resolved)),
             resolvedBy: ($resolvable[0].resolved_by | if . then {username} else null end),
             notes: {nodes: [.notes[] | {id: (.id | tostring), body, system,
               url: "\($url)#note_\(.id)", author: {username: .author.username},
               position: (.position
                 | if . then {newPath: .new_path, newLine: .new_line} else null end),
               awardEmoji: ($emoji_by_note[.id | tostring] // [] | emoji)}]}}]}
      }' "$tmp/gql.json" >"$tmp/fetched.json" || return
  if [[ -n ${WATCH_MR_CACHE:-} ]]; then cp "$tmp/fetched.json" "$WATCH_MR_CACHE/$1.json"; fi
  cat "$tmp/fetched.json"
}

pid=''

PROGRAM=$(cat <<'JQ'
def by_iid: map({key: (.iid | tostring), value: .}) | from_entries;

$old[0] as $old | $todos[0] as $todos
| ($watched[0] | map(select(.author.username != $me)) | by_iid) as $by
| ($notes | map({key: (.iid | tostring), value: .notes}) | from_entries) as $notes_by
| ([$reactions[] | (.iid | tostring) as $iid | .id as $id | .emoji[]
    | select(.user.username != $me)
    | {iid: $iid, key: "\($id):\(.name):\(.user.username)", name, user: .user.username,
       url: "\($by[$iid].web_url)#note_\($id)"}] | group_by(.iid)
  | map({key: .[0].iid, value: .}) | from_entries) as $reactions_by
| ($opened[0] | map(select(.author.username != $me))) as $opened
| ($default[0][0] | if . then {id, status} else null end) as $new_pipeline
| ($old.default_pipeline // null) as $saved_pipeline
| (if $saved_pipeline == null or $saved_pipeline.id <= ($new_pipeline.id // 0)
   then $new_pipeline else $saved_pipeline end) as $default_pipeline
| ($by | with_entries(.key as $k | ($old.mrs[$k] // {}) as $o | .value |= {
    updated_at,
    last_note_id: ([($notes_by[$k] // [])[].id, $o.last_note_id // 0] | max),
    reactions: [($reactions_by[$k] // [])[].key]
  })) as $mrs
| {
    state: {todos: [$todos[].id], opened: [$opened[].iid], mrs: $mrs,
      default_pipeline: $default_pipeline},
    events: (if $old == null then [] else [
      ($todos[] | select(.id as $id | $old.todos | any(. == $id) | not)
        | select(.target.author.username != $me)
        | {kind: "todo", iid: .target.iid, title: .target.title, url: .target_url,
           actor: .author.username, detail: .action_name, branch: .target.source_branch}),
      ($opened[] | select($old | has("opened"))
        | select(.iid as $iid | $old.opened | any(. == $iid) | not)
        | {kind: "opened", iid, title, url: .web_url, actor: .author.username, detail: "opened",
           branch: .source_branch}),
      ($default[0][0] | select($old | has("default_pipeline"))
        | select(. != null and .id > ($old.default_pipeline.id // 0) and .status == "failed")
        | {kind: "default-failed", iid: null, title: null, url: .web_url, actor: "",
           detail: "pipeline \(.id) failed", branch: $default_branch,
           previous: $old.default_pipeline.status}),
      ($by | to_entries[] | .key as $k | .value as $mr | $old.mrs[$k] as $o
        | select($o != null)
        | ($notes_by[$k] // [])[]
        | select(.id > $o.last_note_id and (.system | not) and .author.username != $me)
        | {kind: "note", iid: $mr.iid, title: $mr.title, url: "\($mr.web_url)#note_\(.id)",
           actor: .author.username, detail: (.body | gsub("\\s+"; " ") | .[0:100]),
           branch: $mr.source_branch}),
      ($by | to_entries[] | .key as $k | .value as $mr | $old.mrs[$k].reactions as $o
        | select($o != null)
        | ($reactions_by[$k] // [])[] | select(.key as $key | $o | index($key) | not)
        | {kind: "reaction", iid: $mr.iid, title: $mr.title, url: .url, actor: .user,
           detail: ":\(.name): on your comment", branch: $mr.source_branch})
    ] | map(select(.kind == "opened" or .kind == "default-failed"
        or (.kind == "todo" and .detail == "review_requested")
        or (.iid as $iid | $reviewed | any(. == $iid) | not))) end)
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
# The newest system note of the MR that matches $re tells who did the action.
def actor($re): [.discussions.nodes[].notes.nodes[] | select(.system and (.body | test($re)))
  | .id |= num] | max_by(.id) | .author.username // "";
def norm($me):
  [.discussions.nodes[] | {id, resolvable, resolved, resolved_by: (.resolvedBy.username // ""),
     notes: [.notes.nodes[] | select(.system | not) | .id |= num]}] as $ds
  | {
      iid: (.iid | tonumber), title, url: .webUrl, branch: .sourceBranch, state,
      merge_user: (.mergeUser.username // ""), draft,
      draft_user: actor("^marked this merge request as \\*\\*(draft|ready)\\*\\*"),
      close_user: actor("^closed$"),
      description, labels: (.labels | sort),
      title_user: actor("^changed title "),
      description_user: actor("^changed the description"),
      labels_user: actor("^(added|removed) ~.* labels?( |$)"),
      base: (.diffRefs.baseSha // null), head: (.diffRefs.headSha // null),
      resolved_mine: [$ds[] | select(.resolvable and .resolved
          and .notes[0].author.username == $me)
        | {id, by: .resolved_by, first: .notes[0]}],
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
        | select($review == 0 or any(.[]; .author.username == $me))
        | {last: .[-1], position: .[0].position}]
    };

($data[0].currentUser.username) as $me
| $old[0] as $old
| [$data[].project.mergeRequest | norm($me)] as $now
| ($now | map({key: (.iid | tostring), value: (. as $n | ($old.mrs[.iid | tostring] // {}) as $o
    | {state, draft, pipeline, approved_by, title, description, labels,
       conflicts: (if $n.merge_status | transient then $o.conflicts else $n.conflicts end),
       mergeable: (if $n.merge_status | transient then $o.mergeable else $n.mergeable end),
       last_note_id: ([$n.notes[].id, $o.last_note_id // 0] | max),
       reactions: [$n.reactions[].key], base: $n.base, head: $n.head,
       resolved: [$n.resolved_mine[].id]})}) | from_entries) as $mrs
| [$now[] as $mr | ($old.mrs // {})[$mr.iid | tostring] as $o | $mrs[$mr.iid | tostring] as $n
    | select($o != null)
    | (($mr.notes[] | select(.id > $o.last_note_id)
         | event(if .author.username == $me then "own-comment" else "comment" end; $mr;
             .author.username; (.body | short); .url) + at(.position)),
       ($mr.reactions[] | select(.user != $me) | select(.key as $k | $o.reactions | index($k) | not)
         | event("reaction"; $mr; .user;
             ":\(.name): on " + (if .on == null then "the MR" elif .on == $me then "your comment"
               else "a comment of @\(.on)" end); .url) + at(.position)),
       (select($n.pipeline != $o.pipeline and ($n.pipeline.status | IN("failed", "success")))
         | event("pipeline"; $mr; "";
             "pipeline \($n.pipeline.id) \(if $n.pipeline.status == "success" then "passed"
               else "failed" end)"; null)),
       (($n.approved_by - $o.approved_by)[] | select(. != $me)
         | event("approved"; $mr; .; "approved"; null)),
       (($o.approved_by - $n.approved_by)[] | select(. != $me)
         | event("unapproved"; $mr; .; "approval removed"; null)),
       (select($o.draft != null and $n.draft != $o.draft and $mr.draft_user != $me)
         | if $n.draft then event("draft"; $mr; $mr.draft_user; "marked as draft"; null)
           else event("ready"; $mr; $mr.draft_user; "marked as ready"; null) end),
       (select($o.title != null and $n.title != $o.title and $mr.title_user != $me)
         | event("title"; $mr; $mr.title_user; ($n.title | short); null)),
       (select($o.description != null and $n.description != $o.description
           and $mr.description_user != $me)
         | event("description"; $mr; $mr.description_user; "description changed"; null)),
       (select($o.labels != null and $n.labels != $o.labels and $mr.labels_user != $me)
         | event("labels"; $mr; $mr.labels_user;
             [(($n.labels - $o.labels)[] | "+\(.)"), (($o.labels - $n.labels)[] | "-\(.)")]
             | join(", "); null)),
       (select($n.conflicts and ($o.conflicts | not))
         | event("conflict"; $mr; ""; "merge conflict"; null)),
       (select($n.mergeable and ($o.mergeable | not))
         | event("mergeable"; $mr; "";
             "now mergeable, \($mr.open_threads) open thread(s)"; null)),
       (select($o.state == "opened" and $n.state == "merged")
         | event("merged"; $mr; $mr.merge_user; "merged"; null)
           + if $mr.merge_user == $me then {own: true} else {} end),
       (select($o.state == "opened" and $n.state == "closed")
         | event("closed"; $mr; $mr.close_user; "closed"; null)
           + if $mr.close_user == $me then {own: true} else {} end),
       (select($review == 1 and $o.head != null and $n.head != null and $n.head != $o.head)
         | event("pushed"; $mr; ""; "pushed \($n.head[0:8])"; null)
           + {old_base: $o.base, old_head: $o.head, new_base: $n.base, new_head: $n.head}),
       ($mr.resolved_mine[] | select($review == 1 and .by != $me)
         | select(.id as $id | ($o.resolved // []) | index($id) | not)
         | event("resolved"; $mr; .by; (.first.body | short); .first.url)
           + at(.first.position)))
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
    fetch_mr "$iid" >>"$tmp/mrs.jsonl" || return
  done
  jq -n --argjson review "$review" --slurpfile old "$old" --slurpfile data "$tmp/mrs.jsonl" \
    "$STACK_PROGRAM" >"$tmp/result.json" \
    || { echo "jq could not compare the state" >"$tmp/error"; return 1; }
  jq '.state' "$tmp/result.json" >"$state.tmp" && mv "$state.tmp" "$state"
  jq -c '.events[]' "$tmp/result.json"
}

check_mode() { if ((${#mrs[@]})); then check_stack; else check; fi; }

check() {
  local old=$state since iids iid note user project_json
  if [[ -z $pid ]]; then
    user=$(api user) || return
    project_json=$(api "projects/$project_ref") || return
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
  # Only the newest 100: an older MR is not new.
  api "projects/$pid/merge_requests?state=opened&order_by=created_at&sort=desc&per_page=100" \
    >"$tmp/opened.json" || return
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
  # GraphQL gives no reactions to a fine-grained token. The comments of the user come from the
  # events, one reaction call for each comment.
  : >"$tmp/reactions.jsonl"
  for note in $(jq -r --argjson pid "$pid" --arg me "$me" --slurpfile watched "$tmp/watched.json" \
      '[$watched[0][] | select(.author.username != $me) | .iid] as $iids
      | .[] | select(.project_id == $pid and .note.noteable_type == "MergeRequest")
      | select(.note.noteable_iid | IN($iids[])) | "\(.note.noteable_iid)/\(.note.id)"' \
      "$tmp/events.json"); do
    api "projects/$pid/merge_requests/${note%/*}/notes/${note#*/}/award_emoji?per_page=100" \
      >"$tmp/emoji.json" || return
    jq -c --argjson iid "${note%/*}" --argjson id "${note#*/}" '{iid: $iid, id: $id, emoji: .}' \
      "$tmp/emoji.json" >>"$tmp/reactions.jsonl"
  done
  api "projects/$pid/pipelines?ref=$default_ref&scope=finished&per_page=1" >"$tmp/default.json" \
    || return
  jq -n --slurpfile old "$old" --slurpfile todos "$tmp/todos.json" \
      --slurpfile opened "$tmp/opened.json" \
      --argjson reviewed "$(printf '%s\n' ${skip_mrs[@]+"${skip_mrs[@]}"} | jq -sc .)" \
      --slurpfile watched "$tmp/watched.json" --slurpfile notes "$tmp/notes.jsonl" \
      --slurpfile default "$tmp/default.json" --slurpfile reactions "$tmp/reactions.jsonl" \
      --arg me "$me" --arg default_branch "$default_branch" "$PROGRAM" >"$tmp/result.json" \
    || { echo "jq could not compare the state" >"$tmp/error"; return 1; }
  jq '.state' "$tmp/result.json" >"$state.tmp" && mv "$state.tmp" "$state"
  jq -c '.events[]' "$tmp/result.json"
}

rc=0
check_mode >"$tmp/events" || rc=$?
if ((rc == 0)); then cat "$tmp/events"; exit 0; fi
echo "watch-gitlab: $(cat "$tmp/error")" >&2
case $rc in
  2) exit 5 ;;
  3) exit 4 ;;
  *) exit 1 ;;
esac
