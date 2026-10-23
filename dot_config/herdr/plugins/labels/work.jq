# The watch state of a workspace, from the tokens that the watch scripts in
# ~/.config/agents/bin report: watch_kind, watch_stage, and watch_needs.
#
#   in:  the tokens object of a workspace
#   $glyphs: {value: glyph}, the glyph table of the plugin configuration
#
# Pure, like policy.jq, which includes it.

# A kind with no watch yet is `started`. The hub watches no MR of its own, so it has no
# `started` stage.
def work_stage:
  if .watch_stage then .watch_stage
  elif .watch_kind and .watch_kind != "hub" then "started"
  else "" end;

# The needs-you values, in priority order. Only a live watch knows them.
def work_needs:
  if work_stage == "watching" then .watch_needs // "" | split(",") | map(select(. != ""))
  else [] end;

def work_words: {
  failed: "pipeline failed", conflict: "conflict", reply: "reply",
  requested_changes: "changes requested", commits: "new commits", ready: "ready to merge",
  draft: "draft", todo: "to-do", "main-failed": "main failed" };

# The glyph of the kind, of the stage, and of the first needs-you value. A value with no
# glyph shows nothing.
def work_glyphs($glyphs):
  [.watch_kind // "", work_stage, (work_needs[0] // "")] | map($glyphs[.] // "") | join("");

def work_line($glyphs):
  [work_glyphs($glyphs), (work_needs | map(work_words[.] // .) | join(", "))]
  | map(select(. != "")) | join(" ");
