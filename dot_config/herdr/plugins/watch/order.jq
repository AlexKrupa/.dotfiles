# The order of the worktree workspaces in each herdr worktree group: my work with no live watcher,
# my watched work, debugging, bumps, code reviews, then other kinds. Alphabetical by label in each
# part. The parent rows stay in place. A group with no tokens belongs to the watcher of another
# daemon, which sorts it.
#
#   in:  {workspaces: [<herdr workspace>], tokens: {<id>: {watch_kind, watch_stage}}}
#        workspaces: in sidebar order, from `herdr api snapshot`
#        tokens: the output of sidebar.jq
#   out: [<workspace.move_block params>], one for each group in the wrong order
#
# Pure: watch.sh does the reads and the herdr calls.

# A worktree with no kind is my work from before watchd. A new worktree gets the kind `mine` before
# an agent watches it.
def rank:
  (.watch_kind // "") as $kind
  | if $kind | IN("", "mine") then
      (if .watch_stage == "watching" then 1 else 0 end)
    else
      {debug: 2, bump: 3, review: 4}[$kind] // 5
    end;

# ABC-23 before ABC-123: each run of digits compares as a number.
def label_key: ascii_downcase | [scan("[0-9]+|[^0-9]+") | tonumber? // .];

.tokens as $tokens
| .workspaces as $workspaces
| [$workspaces[] | select(.worktree.is_linked_worktree == false) | .worktree.repo_key] as $parents
| [$workspaces | to_entries[]
    | select(.value.worktree.is_linked_worktree and (.value.worktree.repo_key | IN($parents[])))]
| group_by(.value.worktree.repo_key)
| map(select(any(.[]; $tokens[.value.workspace_id]))
    | (map(.value.workspace_id)) as $current
    | (sort_by(.value | [($tokens[.workspace_id] // {} | rank),
        (.label // "" | label_key)]) | map(.value.workspace_id)) as $sorted
    | select($sorted != $current)
    | {workspace_ids: $sorted}
      + ($workspaces[last.key + 1].workspace_id as $next
         | if $next then {before_workspace_id: $next} else {} end))
