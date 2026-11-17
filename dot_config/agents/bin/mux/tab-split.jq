# The moves of tab-split: park all panes but the anchor in another tab, split the anchor to the
# right, then move the parked panes back. Input is a layout.export response. Include:
#
#   jq -L "$(dirname "$0")" 'include "tab-split"; tab_split_plan'
#
# A --ratio is the share of the first pane, the one that is already in place.

def root: [.. | objects | select(has("root")) | .root] | first;

def first_leaf: if .type == "pane" then .pane_id else .first | first_leaf end;

def leaves: if .type == "pane" then [.pane_id] else (.first | leaves) + (.second | leaves) end;

# Slots on one axis, as in ~/.config/herdr/bin/balance.jq: nested splits of the same direction
# add up, anything else counts as one.
def slots($d):
  if type == "object" and .type == "split" and .direction == $d
  then (.first | slots($d)) + (.second | slots($d)) else 1 end;

# Pre-order: a split is rebuilt before the splits inside it. So when a split is rebuilt, its first
# subtree is still only its first leaf, and a move next to that leaf makes exactly this split.
def moves:
  if .type == "pane" then []
  else [{pane: (.second | first_leaf), target: (.first | first_leaf),
         direction, ratio}]
       + (.first | moves) + (.second | moves) end;

def tab_split_plan:
  root
  | (slots("right")) as $s
  | {anchor: first_leaf, parked: leaves[1:], ratio: ($s / ($s + 1)), moves: moves};
