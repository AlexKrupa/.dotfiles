# The agents panel: repo groups, indented worktrees, and the rank that orders the panel.
#
# Pure, like policy.jq, which includes it.

# No binding reaches a 10th row, so those stay bare. No bullet either: herdr puts its own
# separator between the tokens of a sidebar row.
def slot: if . <= 9 then tostring else "" end;

# herdr trims leading whitespace off a token, but a zero-width space is not whitespace.
def zwsp: "​";

def dot_states: ["working", "blocked", "done", "idle_fresh", "idle", "idle_stale", "unknown"];

# herdr's own `Dots` glyphs, so a row reads like the spaces panel.
def glyph: if . == "idle" then "○" elif . == "unknown" then "·" else "●" end;

# Every agent in panel order, with what its rows need. A group is one repo: its checkout and
# every linked worktree share `repo_key`. A workspace outside a repo is a group of its own,
# and so is an agent whose workspace the snapshot does not list yet.
def agent_rows($s):
  ($s.workspaces // [] | map({key: .workspace_id, value: .}) | from_entries) as $ws
  | [ ($s.agents // [])[]
      | ($ws[.workspace_id] // {}) as $w
      | (.agent_status // "unknown") as $status
      | { pane_id, workspace_id,
          status: (if (["working", "blocked", "done", "idle"] | index($status)) != null
                   then $status else "unknown" end),
          tokens: (.tokens // {}),
          title: (.tokens.session // .terminal_title_stripped // "" | gsub("[\t\r\n]"; " ")),
          seq: (.state_change_seq // 0),
          family: ($w.worktree.repo_key // ("workspace:" + .workspace_id)),
          child: ($w.worktree.is_linked_worktree // false),
          repo: ($w.worktree.repo_name // "") } ]
  | group_by(.family)
  | map(group_by(.workspace_id)
        | map(sort_by(-.seq, .pane_id))
        # The checkout heads its group. Worktrees follow, the most recent first.
        | sort_by((if .[0].child then 1 else 0 end), -.[0].seq, .[0].workspace_id)
        | add
        | (any(.[]; .child | not)) as $parent
        | to_entries
        # A worktree whose checkout runs no agent: the repo name heads the group instead.
        | map(.value + {header: (.value.child and ($parent | not) and .key == 0)}))
  | sort_by(-(map(.seq) | max), .[0].family)
  | add // []
  | to_entries
  | map(.value + {rank: (.key + 1)});

# A token value as herdr stores it. A value that differs from the stored one is written
# again on every sweep.
def herdr_text: gsub("[\u0000-\u001f\u007f-\u009f]"; "") | trim | .[0:80] | trim;

# A worktree row sits 2 columns right of a root row.
def indent: zwsp + "  ";

# An idle agent fades with the time since it went idle.
def dot_state($since; $now):
  if .status != "idle" then .status
  else ($now - ($since[.pane_id] // $now)) as $age
    | if $age < 900 then "idle_fresh" elif $age <= 3600 then "idle" else "idle_stale" end
  end;

# Every token this plugin owns on an agent pane. Empty means clear. The name of the one dot
# token picks its color in config.toml.
def wanted($since; $now):
  dot_state($since; $now) as $state
  | (.title | herdr_text) as $title
  | { ord: ("00" + (.rank | tostring))[-3:],
      rank: (.rank | slot),
      group_parent: (if .header then .repo else "" end),
      idx: "" }
    + (dot_states | map({key: ("dot_" + .), value: ""}) | from_entries)
    # herdr indents every row of an entry after its first, so the name row under a repo
    # header is indented already.
    + { ("dot_" + $state):
          ((if .child and (.header | not) then indent else "" end) + (.status | glyph)),
        title: (if $title == "" then "" elif .child then indent + $title else $title end) };

# One line per pane with any token to change, so watch.sh makes one call for it. Only
# differing tokens, so a write does not feed its own event back as more work.
def pane_line($since; $now):
  . as $r
  | [ wanted($since; $now) | map_values(herdr_text) | to_entries[]
      | select(.value != ($r.tokens[.key] // "")) ]
  | select(length > 0)
  | ["pane", $r.pane_id] + map("\(.key)=\(.value)")
  | join("\t");

# When each idle agent went idle. An agent that is busy or gone drops out.
def idle_since($rows; $since; $now):
  $rows
  | map(select(.status == "idle") | {key: .pane_id, value: ($since[.pane_id] // $now)})
  | from_entries;
