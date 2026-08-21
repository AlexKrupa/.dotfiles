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
    jq -r --slurpfile st "$tmp/state.json" --argjson fg "$fg" -f ../policy.jq |
    jq -cRn '[inputs] | { state:  (.[0] | fromjson),
                          rename: (.[1:] | map(split("\t") | {tab_id: .[0], label: .[1]})) }'
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
  "null" "$(jq -r '.state["wB:t2"] // "null"' <<<"$out")"
check "auto tab is claimed in state" \
  "herdr" "$(jq -r '.state["wA:t1"] // "null"' <<<"$out")"

out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "1 • herdr"')
check "owned tab with a current label is not renamed" \
  "" "$(label_of "$out" wA:t1)"

out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "mine"')
check "user rename is respected"   "1 • mine" "$(label_of "$out" wA:t1)"
check "user rename drops ownership" "null"    "$(jq -r '.state["wA:t1"] // "null"' <<<"$out")"

# Stale state, and the tab renamed back to a bare number.
out=$(run '{"wA:t1":"mine"}' '.result.snapshot.tabs[0].label = "1"')
check "bare number hands the tab back" "1 • herdr" "$(label_of "$out" wA:t1)"

out=$(run '{"wB:t4":"cargo"}' '.result.snapshot.tabs[8].label = "4 • cargo"')
check "ignored command keeps the owned name" "" "$(label_of "$out" wB:t4)"

exit $fail
