# The watch state of a workspace, from the tokens that the herdr plugin `watch` reports:
# watch_kind, watch_stage, watch_needs, watch_stack, and watch_conflict.
#
#   in:  the tokens object of a workspace
#   $glyphs: {value: glyph}, the glyph table of the plugin configuration
#
# Pure, like policy.jq, which includes it.

# A space where an agent runs with no kind is own work: the role skills set their kind at
# the start.
def work_agent_kind: if .watch_kind then . else .watch_kind = "mine" end;

# A kind with no watch yet is `started`. The hub watches no MR of its own, so it has no
# `started` stage. Own work with no watch is the usual state, so it has no stage either.
def work_stage:
  if .watch_stage then .watch_stage
  elif .watch_kind and .watch_kind != "hub" and .watch_kind != "mine" then "started"
  else "" end;

# The needs-you values, in priority order. Only a live watch knows them.
def work_needs:
  if work_stage == "watching" then .watch_needs // "" | split(",") | map(select(. != ""))
  else [] end;

def work_words: {
  failed: "pipeline failed", conflict: "conflict", reply: "reply",
  requested_changes: "changes requested", commits: "new commits", ready: "ready to merge",
  draft: "draft", todo: "to-do", "main-failed": "main failed" };

# The glyph of the kind, of a git-spice stack, of the stage, and of the first needs-you value, else
# of a local conflict with the default branch. A value with no glyph shows nothing. A space after
# a glyph lets the terminal draw it 2 cells wide.
def work_glyphs($glyphs):
  [.watch_kind // "", (if .watch_stack == "1" then "stack" else "" end), work_stage,
    (work_needs[0] // (if .watch_conflict == "1" then "conflict" else "" end))]
  | map($glyphs[.] // "")
  | map(select(. != "")) | join(" ");

def work_line($glyphs):
  [work_glyphs($glyphs), (work_needs | map(work_words[.] // .) | join(", "))]
  | map(select(. != "")) | join(" ");
