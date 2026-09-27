#!/usr/bin/env bash
# Runs no herdr commands and touches no real state, so it is safe in any pane.
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

# The fixture directories sit under this home, so the `~` case does not need the real one.
export HOME=/Users/tester

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# The {pane_id: program} map watch.sh builds from `pane process-info`.
fg=$(jq -c 'to_entries | map(.value.result.process_info as $i
  | { key: .key,
      value: (first($i.foreground_processes[]
                    | select(.pid == $i.foreground_process_group_id) | .name) // "") })
  | from_entries' process-info.json)

# run <state-json> [jq-filter-to-mutate-the-fixture] -> policy output as {rename, state}
#
# policy.jq emits a text stream for watch.sh. The checks below read one object, so this
# folds the stream back into one.
run() {
  printf '%s' "$1" >"$tmp/state.json"
  if [ -n "${2:-}" ]; then jq "$2" snapshot.json; else cat snapshot.json; fi |
    jq -r --slurpfile st "$tmp/state.json" --argjson fg "$fg" --argjson now 10000 \
      -f ../policy.jq |
    jq -cRn '[inputs] | { state:  (.[0] | fromjson),
                          rename: (.[1:] | map(split("\t"))
                                   | map(select(.[0] == "tab") | {tab_id: .[1], label: .[2]})) }'
}

# Empty when the run decided not to rename the tab.
label_of() { jq -r --arg t "$2" '.rename[] | select(.tab_id == $t) | .label' <<<"$1"; }

out=$(run '{}')

check "idle prompt takes the directory"      "1 • herdr"  "$(label_of "$out" wA:t1)"
check "running command takes its name"       "2 • chezmoi" "$(label_of "$out" wA:t2)"
check "agent pane takes the agent name"      "3 • claude" "$(label_of "$out" wA:t3)"
check "exec'd program holding the shell pid" "4 • lazygit" "$(label_of "$out" wA:t4)"
check "idle prompt at home takes a tilde"    "5 • ~"      "$(label_of "$out" wA:t5)"
check "the process group leader wins"        "1 • yazi"   "$(label_of "$out" wB:t1)"
check "manual name kept, number applied"     "2 • agent"  "$(label_of "$out" wB:t2)"
check "pane with no reading is left alone"   ""           "$(label_of "$out" wB:t3)"
check "ignored command is left alone"        ""           "$(label_of "$out" wB:t4)"

check "manual tab is not claimed in state" \
  "null" "$(jq -r '.state.tabs["wB:t2"] // "null"' <<<"$out")"
check "auto tab is claimed in state" \
  "herdr" "$(jq -r '.state.tabs["wA:t1"] // "null"' <<<"$out")"

out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "1 • herdr"')
check "owned tab with a current label is not renamed" \
  "" "$(label_of "$out" wA:t1)"

out=$(run '{"tabs":{"wA:t1":"old"}}' '.result.snapshot.tabs[0].label = "1 • old"')
check "new state format is read" "1 • herdr" "$(label_of "$out" wA:t1)"

out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "mine"')
check "user rename is respected"   "1 • mine" "$(label_of "$out" wA:t1)"
check "user rename drops ownership" "null"    "$(jq -r '.state.tabs["wA:t1"] // "null"' <<<"$out")"

# Stale state, and the tab renamed back to a bare number.
out=$(run '{"wA:t1":"mine"}' '.result.snapshot.tabs[0].label = "1"')
check "bare number hands the tab back" "1 • herdr" "$(label_of "$out" wA:t1)"

out=$(run '{"wB:t4":"cargo"}' '.result.snapshot.tabs[8].label = "4 • cargo"')
check "ignored command keeps the owned name" "" "$(label_of "$out" wB:t4)"

# The agents panel, from a fixture with two repo groups and one plain workspace.
Z=$'​'

# agents <state-json> [fixture-path] -> {state, panes: {pane_id: {token: value}}}, with only
# the tokens the run changes.
agents() {
  printf '%s' "$1" >"$tmp/state.json"
  jq -r --slurpfile st "$tmp/state.json" --argjson fg '{}' --argjson now 10000 \
    -f ../policy.jq "${2:-agents.json}" |
    jq -cRn '[inputs] | { state: (.[0] | fromjson),
      panes: (.[1:] | map(split("\t")) | map(select(.[0] == "pane"))
              | map({ key: .[1],
                      value: (.[2:] | map(capture("^(?<k>[^=]*)=(?<v>.*)$")
                                          | {key: .k, value: .v}) | from_entries) })
              | from_entries) }'
}

# tok <agents-output> <pane_id> <token> -> the value to write, "" to clear, <none> if unchanged
tok() { jq -r --arg p "$2" --arg k "$3" '.panes[$p][$k] // "<none>"' <<<"$1"; }

# fixture <jq-filter> [jq options] -> path of agents.json with the filter applied
fixture() { jq "${@:2}" "$1" agents.json >"$tmp/fixture.json" && printf '%s' "$tmp/fixture.json"; }

out=$(agents '{}')
check "the most recent group ranks first"          "001" "$(tok "$out" wH:p1 ord)"
check "a group with no checkout agent is next"     "002" "$(tok "$out" wP:p1 ord)"
check "worktrees rank by their own activity"       "003" "$(tok "$out" wO:p1 ord)"
check "the checkout heads its own group"           "004" "$(tok "$out" wR:p1 ord)"
check "agents of one worktree rank by activity"    "007" "$(tok "$out" wB:p2 ord)"
check "an agent shows its rank"                    "1"   "$(tok "$out" wH:p1 rank)"
check "a root dot has no lead"                     "●"   "$(tok "$out" wH:p1 dot_working)"
check "a worktree dot is indented"                 "${Z}  ●" "$(tok "$out" wA:p1 dot_blocked)"
check "under a repo header the dot has no lead"    "●"   "$(tok "$out" wP:p1 dot_working)"
check "a group with no checkout agent gets a header" "orphan" "$(tok "$out" wP:p1 group_parent)"
check "other agents get no header"                 "<none>" "$(tok "$out" wA:p1 group_parent)"
check "the old agent idx token is cleared"         ""    "$(tok "$out" wH:p1 idx)"

out=$(agents '{}' "$(fixture '.result.snapshot.agents |=
  (map(if .workspace_id == "wB" then .state_change_seq = 20 else . end) | reverse)')")
check "equal activity ranks by pane id"            "006" "$(tok "$out" wB:p1 ord)"

out=$(agents '{}' "$(fixture '.result.snapshot.agents +=
  [{pane_id: "wX:p1", workspace_id: "wX", state_change_seq: 60}]')")
check "an agent with no known workspace is a root" "·" "$(tok "$out" wX:p1 dot_unknown)"

out=$(agents '{}' "$(fixture '.result.snapshot.agents +=
  [range(1; 4) | {pane_id: "wZ:p\(.)", workspace_id: "wZ", state_change_seq: .}]')")
check "a rank past 9 is padded"                    "010" "$(tok "$out" wZ:p1 ord)"
check "a rank past 9 shows no number"              "<none>" "$(tok "$out" wZ:p1 rank)"

out=$(agents '{}' "$(fixture 'del(.result.snapshot.agents)')")
check "a snapshot with no agents writes no pane"   "{}" "$(jq -c .panes <<<"$out")"

# Feed the tokens of one run back into the fixture: the next run has nothing to write.
out=$(agents '{}')
out=$(agents '{}' "$(fixture '.result.snapshot.agents |= map(.tokens =
  ((.tokens // {}) + ($t[.pane_id] // {}) | with_entries(select(.value != ""))))' \
  --argjson t "$(jq -c .panes <<<"$out")")")
check "a token is not written twice"               "{}" "$(jq -c .panes <<<"$out")"

out=$(agents '{}')
check "a root title is the session"           "Herdr work" "$(tok "$out" wH:p1 title)"
check "a worktree title is indented"          "${Z}  subtract fn" "$(tok "$out" wA:p1 title)"
check "a tab in the session becomes a space"  "${Z}  Calc desc" "$(tok "$out" wB:p1 title)"
check "an agent with no title gets no title"  "<none>" "$(tok "$out" wB:p2 title)"
check "an idle agent seen first is fresh"     "○" "$(tok "$out" wR:p1 dot_idle_fresh)"
check "idle_since starts at now"              "10000" "$(jq -r '.state.idle_since["wR:p1"]' <<<"$out")"
check "a working agent has no idle_since"     "null"  "$(jq -r '.state.idle_since["wH:p1"]' <<<"$out")"

# fade <idle_since of wR:p1> -> the one dot token it sets, at now = 10000
fade() {
  agents "{\"idle_since\":{\"wR:p1\":$1}}" |
    jq -r '.panes["wR:p1"] | to_entries[]
           | select((.key | startswith("dot_")) and .value != "") | .key'
}
check "idle for 899 s is fresh"  "dot_idle_fresh" "$(fade 9101)"
check "idle for 900 s is idle"   "dot_idle"       "$(fade 9100)"
check "idle for 3600 s is idle"  "dot_idle"       "$(fade 6400)"
check "idle for 3601 s is stale" "dot_idle_stale" "$(fade 6399)"

out=$(agents '{"idle_since":{"wR:p1":5000}}')
check "idle_since keeps its first value" "5000" "$(jq -r '.state.idle_since["wR:p1"]' <<<"$out")"

out=$(agents '{"idle_since":{"gone:p1":1,"wA:p1":1}}')
check "idle_since drops a gone pane"      "null" "$(jq -r '.state.idle_since["gone:p1"]' <<<"$out")"
check "idle_since drops a busy agent"     "null" "$(jq -r '.state.idle_since["wA:p1"]' <<<"$out")"

out=$(agents '{}' "$(fixture '.result.snapshot.agents |=
  map(if .pane_id == "wA:p1" then .tokens = {dot_idle: "x"} else . end)')")
check "a new state clears the old dot"    "" "$(tok "$out" wA:p1 dot_idle)"

out=$(agents '{}' "$(fixture '.result.snapshot.agents[0].tokens.session = "a=b \\ c"')")
check "a title keeps = and backslash"     'a=b \ c' "$(tok "$out" wH:p1 title)"

# herdr stores a token value without control characters, trimmed, and cut to 80 code points.
# A wanted value that differs from the stored one is written again on every sweep.
long=$(printf 'x%.0s' {1..80})
out=$(agents '{}' "$(fixture '.result.snapshot.agents[2].terminal_title_stripped = $t' --arg t "$long")")
check "a long title is cut as herdr cuts it" \
  "${Z}  ${long:0:77}" "$(tok "$out" wA:p1 title)"

out=$(agents '{}' "$(fixture '.result.snapshot.agents[2].terminal_title_stripped = "sub\u0007tract  "')")
check "a title loses control characters and end spaces" \
  "${Z}  subtract" "$(tok "$out" wA:p1 title)"

# herdr <panes-json> -> the token values as herdr stores them
herdr_store() {
  jq -c 'map_values(map_values(gsub("[\u0000-\u001f\u007f-\u009f]"; "") | trim | .[0:80] | trim))' <<<"$1"
}
cut=$(printf 'y%.0s' {1..76})
out=$(agents '{}' "$(fixture '.result.snapshot.agents[2].terminal_title_stripped = $t' --arg t "$cut   tail")")
out=$(agents '{}' "$(fixture '.result.snapshot.agents |= map(.tokens =
  ((.tokens // {}) + ($t[.pane_id] // {}) | with_entries(select(.value != ""))))
  | .result.snapshot.agents[2].terminal_title_stripped = $c + "   tail"' \
  --arg c "$cut" --argjson t "$(herdr_store "$(jq -c .panes <<<"$out")")")")
check "a title cut at a space is not written twice" "{}" "$(jq -c .panes <<<"$out")"

exit $fail
