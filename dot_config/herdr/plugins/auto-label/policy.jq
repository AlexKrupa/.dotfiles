# Decide every herdr tab label and slot number from one `herdr api snapshot`.
#
#   in:  snapshot JSON on stdin, --slurpfile st <state.json>,
#        --argjson fg {pane_id: foreground program}, a shell name for an idle pane
#   out: with `jq -r`, line 1 is {tab_id: base} as JSON, every line after is
#        "<kind>\t<id>\t<value>". One text stream, so the caller needs no second jq to
#        take it apart. `tab` is a label to apply, `workspace` and `pane` an `idx` token
#        to report, empty to clear.
#
# Pure: no herdr calls, no clock, no files.

def ignored: ["ls","cd","cat","echo","clear","git","jj","rm","cp","mv","grep","rg","fd",
              "which","type","printf","test"];

# A pane whose foreground program is a shell is sitting at its prompt.
def shells: ["fish","bash","zsh","sh","dash","ksh","nu"];

def cap: .[0:20] | sub(" +$"; "");

def basename: sub("/+$"; "") | split("/") | last | if . == "" then "/" else . end;

# No binding reaches a 10th row, so those stay bare. No bullet either: herdr puts its own
# separator between the tokens of a sidebar row.
def slot: if . <= 9 then tostring else "" end;

# The workspaces in sidebar order, which `switch_workspace` counts. A worktree child sits
# under the checkout of its repo, wherever the list itself holds it, so `.number` is the
# wrong slot for every space below such a group.
def packed:
  . as $ws
  | [ $ws | to_entries[]
      | .value.worktree.repo_key as $repo
      | (if $repo == null
         then .key
         else first($ws | to_entries[] | select(.value.worktree.repo_key == $repo) | .key)
         end) as $anchor
      | { row: [$anchor, (if .value.worktree.is_linked_worktree then .key else -1 end)],
          workspace: .value } ]
  | sort_by(.row) | map(.workspace);

# The base label for one pane, or null to leave the tab's label alone.
def label_of($pane; $program):
  if $pane == null then null
  # An agent rewrites its title with its current task, so use the agent name instead.
  elif $pane.agent != null then $pane.agent
  # No reading for this pane: it went away, or the process call failed.
  elif $program == null or $program == "" then null
  elif (shells | index($program)) then
    (if $pane.cwd == env.HOME then "~" else ($pane.cwd // "" | basename) end)
  elif (ignored | index($program)) then null
  else $program
  end
  | if . == null or . == "" then null else cap end;

($st[0] // {}) as $owned
| .result.snapshot as $s
| ($s.panes   | map({key: .pane_id, value: .})           | from_entries) as $pane
| ($s.layouts | map({key: .tab_id,  value: .focused_pane_id}) | from_entries) as $focus
| [ $s.tabs[]
    | . as $t
    # `number` is a creation counter, so position comes from snapshot order.
    | (($s.tabs | map(select(.workspace_id == $t.workspace_id) | .tab_id)
                | index($t.tab_id)) + 1) as $pos
    | ($t.label | sub("^[0-9]+ • "; "")) as $base
    | (if ($base | test("^[0-9]+$")) or ($owned[$t.tab_id] == $base)
       then "auto" else "manual" end) as $mode
    | $focus[$t.tab_id] as $pane_id
    | label_of($pane[$pane_id]; $fg[$pane_id]) as $want
    | (if $mode == "manual" then $base
       elif $want == null then (if ($base | test("^[0-9]+$")) then null else $base end)
       else $want
       end) as $newbase
    | select($newbase != null)
    | { tab_id: $t.tab_id, mode: $mode, current: $t.label, base: $newbase,
        label: (($pos | tostring) + " • " + $newbase) } ]
| (map(select(.mode == "auto") | {key: .tab_id, value: .base}) | from_entries | tojson),
  (.[] | select(.label != .current) | ["tab", .tab_id, .label] | @tsv),

  # A display-only token, not a rename: a name the user typed is never touched, so none of
  # the ownership state above applies. Emitting only a differing token also stops the write
  # from feeding its own event back as more work.
  (($s.workspaces // []) | packed | to_entries[]
   | (.key + 1 | slot) as $idx
   | .value
   | select((.tokens.idx // "") != $idx)
   | ["workspace", .workspace_id, $idx] | @tsv),
  # An agent has no slot of its own. Its position in the agents list is what `focus_agent`
  # counts.
  (($s.agents // []) | to_entries[]
   | (.key + 1 | slot) as $idx
   | .value
   | select((.tokens.idx // "") != $idx)
   | ["pane", .pane_id, $idx] | @tsv),
  # A pane that stops being an agent keeps the token it was given, and nothing above
  # reaches it: the agents list no longer holds it.
  (($s.agents // []) | map(.pane_id)) as $agent_panes
  | ($s.panes[]?
     | select((.tokens.idx // "") != "" and ((.pane_id | IN($agent_panes[])) | not))
     | ["pane", .pane_id, ""] | @tsv)
