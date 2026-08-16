# Decide every herdr tab label from one `herdr api snapshot`.
#
#   in:  snapshot JSON on stdin, --slurpfile st <state.json>
#   out: with `jq -r`, line 1 is {tab_id: base} as JSON, every line after is
#        "<tab_id>\t<label>". One text stream, so the caller needs no second jq to
#        take it apart.
#
# Pure: no herdr calls, no clock, no files. tests/test.sh covers every branch.

def ignored: ["ls","cd","cat","echo","clear","git","jj","rm","cp","mv","grep","rg","fd",
              "which","type","printf","test"];

def cap: .[0:20] | sub(" +$"; "");

def basename: sub("/+$"; "") | split("/") | last | if . == "" then "/" else . end;

# The base label for one pane, or null to leave the tab's label alone.
def label_of($pane):
  if $pane == null then null
  # An agent rewrites its title with its current task, so use the agent name instead.
  elif $pane.agent != null then $pane.agent
  else
    (($pane.terminal_title_stripped // "") | split(" ") | map(select(length > 0))) as $w
    | if ($w | length) == 0 then null
      # fish's fish_title always appends prompt_pwd, so a trailing path means fish set this
      # title: one token is an idle prompt, more than one is a running command.
      elif ($w[-1] | test("^[~/]")) then
        ($w[0] | basename) as $cmd
        | if ($w | length) == 1 then $cmd
          elif (ignored | index($cmd)) then null
          else $cmd
          end
      # No trailing path: the program set this title, so use it as it is.
      else $pane.terminal_title_stripped
      end
  end
  | if . == null then null else cap end;

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
    | label_of($pane[$focus[$t.tab_id]]) as $want
    | (if $mode == "manual" then $base
       # Nothing to derive: keep an owned name, but leave a generated label alone.
       elif $want == null then (if ($base | test("^[0-9]+$")) then null else $base end)
       else $want
       end) as $newbase
    | select($newbase != null)
    | { tab_id: $t.tab_id, mode: $mode, current: $t.label, base: $newbase,
        label: (($pos | tostring) + " • " + $newbase) } ]
| (map(select(.mode == "auto") | {key: .tab_id, value: .base}) | from_entries | tojson),
  (.[] | select(.label != .current) | [.tab_id, .label] | @tsv)
