# Walks over a tab's layout tree. Input is a layout.export response. Include:
#
#   jq -L "$(dirname "$0")" 'include "balance"; ...'

def root: [.. | objects | select(has("root")) | .root] | first;

# A path is an array of booleans (API schema: LayoutSetSplitRatioParams): false
# selects `first`, true selects `second`. The root split is [].
def node($p): reduce $p[] as $b (.; if $b then .second else .first end);

def pathto($id):
  if .type == "pane" then (if .pane_id == $id then [[]] else [] end)
  else ((.first | pathto($id)) | map([false] + .))
     + ((.second | pathto($id)) | map([true] + .)) end;

# Slots on one axis: nested splits of the same direction add up, anything else
# counts as one. Counting leaf panes instead would give the left column of
# `a | (b / c / d)` a quarter of the width instead of a half.
def slots($d):
  if type == "object" and .type == "split" and .direction == $d
  then (.first | slots($d)) + (.second | slots($d)) else 1 end;

# `<path> <ratio>` per split that is not already at its target. A ratio of 0.5
# everywhere does not equalize panes: for `a | (b | c)` it gives 50/25/25, while
# slot weighting gives 33/33/33.
#
# The server keeps ratios as f32 and hands 1/3 back as 0.33333331, so the
# comparison needs a tolerance. An exact one rewrites every split on every press.
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

# The group is the unbroken run of $dir splits that ends at $path. A run further
# up is another group, so a node whose own parent splits the other way is in no
# run and nothing moves. $path is a pane for the split key, and the collapsed
# split for the close key.
def equalize_at($path; $dir):
  root as $root
  | [range(0; $path | length) as $i | ($root | node($path[0:$i]) | .direction)] as $up
  | ($up | length) as $n
  | (first(range($n; 0; -1) | select($up[. - 1] != $dir)) // 0) as $top
  | $root | node($path[0:$top]) | ratios($path[0:$top]; $dir);

# $dir "" is the whole tab, both axes.
def equalize($pane; $dir):
  if $dir == "" then root | ratios([]; "")
  else (root | pathto($pane) | first) as $path
    | if $path == null then empty else equalize_at($path; $dir) end
  end;

# `<direction> <path>`: the split that closing $pane collapses, and its path.
# Closing hoists the other side into that spot, so the path still leads to the
# group afterwards.
def close_target($pane):
  root as $root
  | ($root | pathto($pane) | first) as $path
  | select($path != null and ($path | length) > 0)
  | "\($root | node($path[0:-1]) | .direction) \($path[0:-1] | tojson)";
