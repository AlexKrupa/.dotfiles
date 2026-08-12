# Shared walks over a tab's layout tree, for bin/equalize-panes and
# bin/close-pane. Include with:
#
#   jq -L "$(dirname "$0")" 'include "layout"; ...'
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

def panes: [.. | objects | .pane_id? // empty];

# Slots on one axis: nested splits of the same direction add up, anything else
# counts as one. In `a | (b / c / d)` the root's second side is one column, so
# both columns come out equal and the stack is evened on its own. Counting every
# leaf pane instead would give the left column 1/4 of the width.
def slots($d):
  if type == "object" and .type == "split" and .direction == $d
  then (.first | slots($d)) + (.second | slots($d)) else 1 end;

# `<path> <ratio>` per split under this node, ratio = same-axis slots on the
# first side / slots in total. A split ratio of 0.5 everywhere does not equalize
# panes: for `a | (b | c)` it gives 50/25/25, while this gives 33/33/33. With a
# direction, the walk stops where the direction changes, which is where the
# group ends.
def ratios($p; $dir):
  if type == "object" and .type == "split" and ($dir == "" or .direction == $dir) then
    (.direction as $d
      | (.first | slots($d)) as $a
      | (.second | slots($d)) as $b
      | "\($p | tojson) \($a / ($a + $b))"),
    (.first  | ratios($p + [false]; $dir)),
    (.second | ratios($p + [true]; $dir))
  else empty end;

# Every split to change so the group around $pane comes out even. $dir "" is the
# whole tab, both axes. Otherwise the group is the unbroken run of $dir splits
# the pane sits in, found by walking its ancestors and then back down through
# same-direction splits only; a run further up is a different group.
def equalize($pane; $dir):
  root as $root
  | if $dir == "" then $root | ratios([]; "")
    else
      ($root | pathto($pane) | first) as $path
      | if $path == null then empty else
          [range(0; $path | length) as $i | ($root | node($path[0:$i]) | .direction)] as $up
          | (reduce range(0; $up | length) as $i ({ start: null, top: null };
              if $up[$i] == $dir
              then { start: (.start // $i), top: (.start // $i) }
              else { start: null, top: .top } end) | .top) as $top
          | if $top == null then empty
            else $root | node($path[0:$top]) | ratios($path[0:$top]; $dir) end
        end
    end;

# `<direction> <pane>`: the split that closing $pane collapses, and a pane on the
# other side of it to even that group around afterwards. Nothing when $pane is
# the whole tab and the close takes the tab with it.
def close_target($pane):
  root as $root
  | ($root | pathto($pane) | first) as $path
  | select($path != null and ($path | length) > 0)
  | ($root | node($path[0:-1])) as $parent
  | ($parent | if $path[-1] then .first else .second end) as $sibling
  | "\($parent.direction) \($sibling | panes | first)";
