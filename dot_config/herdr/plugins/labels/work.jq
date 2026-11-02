# The watch state of a workspace, from the tokens that the herdr plugin `watch` reports:
# watch_kind, watch_stage, watch_needs, watch_stack, and watch_conflict.
#
#   in:  the tokens object of a workspace
#   $glyphs: {value: glyph}, the glyph table of the plugin configuration
#
# Pure, like policy.jq, which includes it.

# A kind with no watch yet is `started`. The hub watches no MR of its own, so it has no
# `started` stage. Own work with no watch is the usual state, so it has no stage either.
def work_stage:
  if .watch_stage then .watch_stage
  elif .watch_kind and .watch_kind != "hub" and .watch_kind != "mine" then "started"
  else "" end;

# The needs-you values, in priority order.
def work_needs: .watch_needs // "" | split(",") | map(select(. != ""));

# The needs-you values win over a local conflict. With `$all_needs` false, the first one only. The
# space after a glyph lets the terminal draw it 2 cells wide.
def work_glyphs($glyphs; $all_needs):
  (work_needs | if $all_needs then . else .[:1] end) as $needs
  | [.watch_kind // "", (if .watch_stack == "1" then "stack" else "" end), work_stage,
      ($needs[] // (if .watch_conflict == "1" then "conflict" else "" end))]
  | map($glyphs[.] // "")
  | map(select(. != "")) | join(" ");
