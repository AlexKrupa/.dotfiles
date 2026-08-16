# Shared walks over a tab's layout tree, for the equalize and close
# subcommands of bin/balance-panes.sh. Include with:
#
#   jq -L "$(dirname "$0")" 'include "balance"; ...'
#
# Input is a layout.export response. Covered by bin/tests/test.sh.

# The tree, wherever it sits in the response.
def root: [.. | objects | select(has("root")) | .root] | first;

# The node a path leads to. A path is an array of booleans (API schema:
# LayoutSetSplitRatioParams): false selects `first`, true selects `second`. The
# root split is [].
def node($p): reduce $p[] as $b (.; if $b then .second else .first end);

# Path to a pane, or nothing when the tree does not hold it. [] for a tab of one
# pane, where the root is the pane itself.
def pathto($id):
  if .type == "pane" then (if .pane_id == $id then [[]] else [] end)
  else ((.first | pathto($id)) | map([false] + .))
     + ((.second | pathto($id)) | map([true] + .)) end;

# Slots on one axis: nested splits of the same direction add up, anything else
# counts as one. In `a | (b / c / d)` the root's second side is one column, so
# both columns come out equal and the stack is evened on its own. Counting every
# leaf pane instead would give the left column 1/4 of the width.
def slots($d):
  if type == "object" and .type == "split" and .direction == $d
  then (.first | slots($d)) + (.second | slots($d)) else 1 end;

# `<path> <ratio>` per split under this node that is not already there, ratio =
# same-axis slots on the first side / slots in total. A split ratio of 0.5
# everywhere does not equalize panes: for `a | (b | c)` it gives 50/25/25, while
# this gives 33/33/33. With a direction, the walk stops where the direction
# changes, which is where the group ends.
#
# Splits already at their target are left out, so evening an even tab writes
# nothing. The server keeps ratios as f32 and hands 1/3 back as 0.33333331, so
# that comparison needs a tolerance; an exact one would rewrite every split on
# every press.
def ratios($p; $dir):
  if type == "object" and .type == "split" and ($dir == "" or .direction == $dir) then
    (.direction as $d
      | (.first | slots($d)) as $a
      | (.second | slots($d)) as $b
      | ($a / ($a + $b)) as $r
      | select(((.ratio - $r) | fabs) > 0.000001)
      | "\($p | tojson) \($r)"),
    (.first  | ratios($p + [false]; $dir)),
    (.second | ratios($p + [true]; $dir))
  else empty end;

# Every split to change so the group at $path comes out even. The group is the
# unbroken run of $dir splits that ends at $path: walk up while the ancestors
# keep that direction, then back down through same-direction splits only. A run
# further up is another group, so a node whose own parent splits the other way
# is in no run and nothing moves. $path is a pane for the split key, and the
# collapsed split for the close key - both name the spot the group forms around.
def equalize_at($path; $dir):
  root as $root
  | [range(0; $path | length) as $i | ($root | node($path[0:$i]) | .direction)] as $up
  | ($up | length) as $n
  | (first(range($n; 0; -1) | select($up[. - 1] != $dir)) // 0) as $top
  | $root | node($path[0:$top]) | ratios($path[0:$top]; $dir);

# The same around the pane $dir splits it. $dir "" is the whole tab, both axes.
def equalize($pane; $dir):
  if $dir == "" then root | ratios([]; "")
  else (root | pathto($pane) | first) as $path
    | if $path == null then empty else equalize_at($path; $dir) end
  end;

# `<direction> <path>`: the split that closing $pane collapses, and its path.
# Closing hoists the other side into that spot, so the path still leads to the
# group afterwards. A pane there instead would only name the group when the
# other side is a single pane. Nothing when $pane is the whole tab and the close
# takes the tab with it.
def close_target($pane):
  root as $root
  | ($root | pathto($pane) | first) as $path
  | select($path != null and ($path | length) > 0)
  | "\($root | node($path[0:-1]) | .direction) \($path[0:-1] | tojson)";
