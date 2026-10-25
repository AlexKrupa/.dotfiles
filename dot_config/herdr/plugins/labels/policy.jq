# Decide every herdr tab label and slot number from one `herdr api snapshot`.
#
#   in:  snapshot JSON on stdin, --slurpfile st <state.json>,
#        --argjson fg {pane_id: foreground program}, a shell name for an idle pane,
#        --argjson now <epoch seconds>,
#        --argjson glyphs <glyph table, see work.jq>
#   out: with `jq -r`, line 1 is the new state as JSON, every line after is
#        "<kind>\t<id>\t...". It is one text stream. The caller needs no second jq to
#        split it. `tab` is a label to apply. `workspace` and `pane` are followed by
#        "<name>=<value>" fields, one per token to report. An empty value clears the token.
#        The name `@title` is the pane title, not a token.
#
# Pure: no herdr calls, no clock, no files.

include "agents" {search: "./"};
include "work" {search: "./"};

def ignored: ["ls","cd","cat","echo","clear","git","jj","rm","cp","mv","grep","rg","fd",
              "which","type","printf","test"];

# A pane whose foreground program is a shell is sitting at its prompt.
def shells: ["fish","bash","zsh","sh","dash","ksh","nu"];

def cap($length): .[0:$length] | sub(" +$"; "");

def linked: .worktree.is_linked_worktree == true;

def basename: sub("/+$"; "") | split("/") | last | if . == "" then "/" else . end;

# The base label for one pane, or null to leave the tab's label alone.
def label_of($pane; $program):
  if $pane == null then null
  elif $pane.agent != null then $pane | agent_label | cap(40)
  else
    # No reading for this pane: it went away, or the process call failed.
    if $program == null or $program == "" then null
    elif (shells | index($program)) then
      (if $pane.cwd == env.HOME then "~" else ($pane.cwd // "" | basename) end)
    elif (ignored | index($program)) then null
    else $program
    end
    | if . == null or . == "" then null else cap(20) end
  end;

($st[0] // {}) as $state
# The state was a bare {tab_id: base} map before it held more than tabs.
| (if $state | has("tabs") then $state.tabs else $state end) as $owned
| .result.snapshot as $s
| agent_rows($s) as $rows
| ($state.idle_since // {}) as $since
| ($s.panes   | map({key: .pane_id, value: .})           | from_entries) as $pane
| ($s.layouts | map({key: .tab_id,  value: .focused_pane_id}) | from_entries) as $focus
# In a tab with more than one agent, each agent pane shows its label on its border. herdr
# draws this title over a manual pane label, so a pane with one gets none.
| ($state.titled // {}) as $titled
| ($s.panes | map(select(.agent != null)) | group_by(.tab_id) | map(select(length > 1))
   | add // [] | map(select((.label // "") == "") | {key: .pane_id, value: agent_label})
   | from_entries) as $titles
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
| ({ tabs: (map(select(.mode == "auto") | {key: .tab_id, value: .base}) | from_entries),
     idle_since: idle_since($rows; $since; $now),
     titled: ($titles | map_values(true)) }
   | tojson),
  # Not @tsv: it writes `\` as `\\`, and `read -r` keeps both.
  (.[] | select(.label != .current) | ["tab", .tab_id, .label] | join("\t")),

  # A display-only token, not a rename: a name the user typed is never touched, so none of
  # the ownership state above applies. Emitting only a differing token also stops the write
  # from feeding its own event back as more work.
  #
  # The slot is the sidebar row, which is what `alt+1..9` counts. herdr appends a new
  # worktree to the end of its list, but the sidebar puts it under its checkout. A collapsed
  # group hides rows from that count too, but no client reports that state.
  #
  # The watch glyphs share the token: the spaces row must stay one line.
  (($s.workspaces // [] | sort_by(.number)) as $list
   | ($list | map(select(linked | not) | .worktree.repo_key // empty)) as $checkouts
   | [ $list[]
       | select(linked and (.worktree.repo_key as $k | any($checkouts[]; . == $k)) | not)
       | ., (select(linked | not) | .worktree.repo_key // empty) as $k
            | $list[] | select(linked and .worktree.repo_key == $k) ]
   | to_entries[]
   | (.key + 1 | slot) as $slot
   | .value
   | .workspace_id as $id
   | (.tokens // {} | if any($rows[]; .workspace_id == $id) then work_agent_kind else . end
      | work_glyphs($glyphs)) as $work
   | ([$slot, $work] | map(select(. != "")) | join(" ")) as $idx
   | select((.tokens.idx // "") != $idx)
   | ["workspace", .workspace_id, "idx=" + $idx] | @tsv),
  # This plugin sets the panel order: herdr sorts by `ord`, and `focus_agent` counts the panel.
  ($rows[] | pane_line($since; $now; $glyphs)),
  # The snapshot title can come from another reporter, so only a title in state is cleared.
  ($s.panes[]
   | .pane_id as $id
   | ($titles[$id] // "") as $want
   | select(if $want == "" then $titled[$id] != null else $want != (.title // "") end)
   | ["pane", $id, "@title=" + $want] | join("\t"))
