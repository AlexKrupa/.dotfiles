# Decide every herdr tab label from one `herdr api snapshot`.
#
#   in:  snapshot JSON on stdin, --slurpfile st <state.json>,
#        --argjson fg {pane_id: foreground program}, a shell name for an idle pane
#   out: with `jq -r`, line 1 is {tab_id: base} as JSON, every line after is
#        "<tab_id>\t<label>". One text stream, so the caller needs no second jq to
#        take it apart.
#
# Pure: no herdr calls, no clock, no files.

def ignored: ["ls","cd","cat","echo","clear","git","jj","rm","cp","mv","grep","rg","fd",
              "which","type","printf","test"];

# A pane whose foreground program is a shell is sitting at its prompt.
def shells: ["fish","bash","zsh","sh","dash","ksh","nu"];

def cap: .[0:20] | sub(" +$"; "");

def basename: sub("/+$"; "") | split("/") | last | if . == "" then "/" else . end;

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
  (.[] | select(.label != .current) | [.tab_id, .label] | @tsv)
