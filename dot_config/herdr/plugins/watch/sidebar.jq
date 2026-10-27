# The sidebar tokens of each herdr workspace in a worktree that the daemon knows. The labels plugin
# shows them.
#
#   in:  {subs: [<agent record> + {live, needs}], worktrees: {<path>: <worktree state>},
#         folders: {<id>: <folder>}}
#        subs: the agent records of the daemon. `repo` is the worktree of the agent.
#        needs: the needs-you values of the check engine state of the agent
#        worktrees: the state of each worktree that the daemon knows: kind, stage, stack, conflict,
#          and the needs-you values of the last check of each key of the worktree
#        folders: the folder of each herdr workspace
#   out: {<id>: {watch_kind, watch_stage, watch_needs, watch_stack, watch_conflict}}. An empty
#        value clears the token.
#
# Pure: watch.sh does the reads and the herdr calls.

def mode_kind: {stack: "mine", review: "review", hub: "hub"}[.mode] // "";

def ordered_unique: reduce .[] as $value ([]; if any(.[]; . == $value) then . else . + [$value] end);

def worktree_path($worktrees):
  . as $folder
  | [$worktrees | keys[] | . as $path
      | select($folder == $path or ($folder | startswith($path + "/")))]
  | max_by(length);

(.worktrees // {}) as $worktrees
| (.subs | map(select(.live)) | group_by(.repo) | map({key: .[0].repo, value: .}) | from_entries)
  as $live
| (.folders // {}) | to_entries
| map((.value | worktree_path($worktrees)) as $path | select($path)
  | $worktrees[$path] as $state | $live[$path] as $subs
  | {key: .key, value:
      ((if $subs then
          {watch_kind: ($state.kind // ($subs[0] | mode_kind)), watch_stage: "watching",
           watch_needs: ([$subs[].needs[]] | ordered_unique | join(","))}
        else
          {watch_kind: ($state.kind // ""), watch_stage: ($state.stage // ""),
           watch_needs: ([$state.needs // {} | .[][]] | ordered_unique | join(","))}
        end)
       + {watch_stack: (if ($state.stack // [] | length) >= 2 then "1" else "" end),
          watch_conflict: (if ($state.conflict // [] | length) > 0 then "1" else "" end)})})
| from_entries
