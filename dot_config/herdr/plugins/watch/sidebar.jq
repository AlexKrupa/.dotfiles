# The sidebar tokens of each herdr workspace with watch data. The labels plugin shows them.
#
#   in:  {workspaces: {<id>: {kind, stage}}, subs: [<subscription record> + {live, needs}],
#         worktrees: {<path>: <worktree state>}, folders: {<id>: <folder>}}
#        workspaces: the files $WATCHD_DIR/workspaces/<id>.json of the watch daemon
#        needs: the needs-you values of the check engine state of the subscription
#        worktrees: the local state of each worktree that the daemon knows
#        folders: the folder of each herdr workspace
#   out: {<id>: {watch_kind, watch_stage, watch_needs, watch_stack, watch_conflict}}. An empty
#        value clears the token.
#
# Pure: watch.sh does the reads and the herdr calls.

# A live subscription in a workspace with no kind has the kind of its mode.
def mode_kind: {stack: "mine", review: "review", hub: "hub"}[.mode] // "";

# The state of the worktree with the longest path that is the folder or a parent of it.
def worktree_of($worktrees):
  . as $folder
  | [$worktrees | keys[] | . as $path
      | select($folder == $path or ($folder | startswith($path + "/")))]
  | max_by(length) as $path
  | if $path then $worktrees[$path] else null end;

(.worktrees // {}) as $worktrees
| ((.folders // {}) | map_values(worktree_of($worktrees))) as $matched
| .workspaces as $files
| (.subs | map(select(.live and .herdr_workspace)) | group_by(.herdr_workspace)
  | map({key: .[0].herdr_workspace, value: .}) | from_entries) as $live
| ([$files | keys[]] + [$live | keys[]] | unique)
| map(. as $id | ($files[$id] // {}) as $file | $live[$id] as $subs
  | {key: $id, value:
      (if $subs then
        {watch_kind: ($file.kind // ($subs[0] | mode_kind)), watch_stage: "watching",
         watch_needs: ([$subs[].needs[]]
           | reduce .[] as $n ([]; if any(.[]; . == $n) then . else . + [$n] end) | join(","))}
      else
        {watch_kind: ($file.kind // ""), watch_stage: ($file.stage // ""), watch_needs: ""}
      end)})
| from_entries
| . as $tokens
| ([$tokens | keys[]] + [$matched | to_entries[] | select(.value) | .key] | unique)
| map(. as $id | {key: $id, value:
    (($tokens[$id] // {watch_kind: "", watch_stage: "", watch_needs: ""})
      + {watch_stack: (if ($matched[$id].stack // [] | length) >= 2 then "1" else "" end),
         watch_conflict: (if ($matched[$id].conflict // [] | length) > 0 then "1" else "" end)})})
| from_entries
