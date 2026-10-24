# The sidebar tokens of each herdr workspace with watch data. The labels plugin shows them.
#
#   in:  {workspaces: {<id>: {kind, stage}}, subs: [<subscription record> + {live, needs}]}
#        workspaces: the files $WATCHD_DIR/workspaces/<id>.json of the watch daemon
#        needs: the needs-you values of the check engine state of the subscription
#   out: {<id>: {watch_kind, watch_stage, watch_needs}}. An empty value clears the token.
#
# Pure: watch.sh does the reads and the herdr calls.

# A live subscription in a workspace with no kind has the kind of its mode.
def mode_kind: {stack: "mine", review: "review", hub: "hub"}[.mode] // "";

.workspaces as $files
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
