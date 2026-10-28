# The order of the worktree workspaces in each herdr worktree group: my work first, then code
# reviews, then the rest. Alphabetical by label in each kind. The parent rows stay in place.
#
#   in:  {workspaces: [<herdr workspace>], tokens: {<id>: {watch_kind}}}
#        workspaces: in sidebar order, from `herdr api snapshot`
#        tokens: the output of sidebar.jq
#   out: [<workspace.move_block params>], one for each group in the wrong order
#
# Pure: watch.sh does the reads and the herdr calls.

def kind_rank: {mine: 0, review: 1}[. // ""] // 2;

.tokens as $tokens
| .workspaces as $workspaces
| [$workspaces[] | select(.worktree.is_linked_worktree == false) | .worktree.repo_key] as $parents
| [$workspaces | to_entries[]
    | select(.value.worktree.is_linked_worktree and (.value.worktree.repo_key | IN($parents[])))]
| group_by(.value.worktree.repo_key)
| map((map(.value.workspace_id)) as $current
    | (sort_by(.value | [($tokens[.workspace_id].watch_kind | kind_rank),
        (.label // "" | ascii_downcase)]) | map(.value.workspace_id)) as $sorted
    | select($sorted != $current)
    | {workspace_ids: $sorted}
      + ($workspaces[last.key + 1].workspace_id as $next
         | if $next then {before_workspace_id: $next} else {} end))
