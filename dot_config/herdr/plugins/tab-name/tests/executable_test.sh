#!/usr/bin/env bash
# Checks policy.jq against tests/snapshot.json. Runs no herdr commands and touches no
# real state, so it is safe in any pane. Run: tests/test.sh
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

# run <state-json> [jq-filter-to-mutate-the-fixture] -> policy output as {rename, state}
#
# policy.jq emits a text stream for watch.sh's benefit. The checks below read it as one
# object, so this folds the stream back into that shape.
run() {
  printf '%s' "$1" >"$tmp/state.json"
  if [ -n "${2:-}" ]; then jq "$2" snapshot.json; else cat snapshot.json; fi |
    jq -r --slurpfile st "$tmp/state.json" -f ../policy.jq |
    jq -cRn '[inputs] | { state:  (.[0] | fromjson),
                          rename: (.[1:] | map(split("\t") | {tab_id: .[0], label: .[1]})) }'
}

# The label a policy run assigned to one tab, empty when it decided not to rename it.
label_of() { jq -r --arg t "$2" '.rename[] | select(.tab_id == $t) | .label' <<<"$1"; }

out=$(run '{}')

check "idle prompt takes the directory"      "1 • herdr"           "$(label_of "$out" wA:t1)"
check "command plus path takes the command"  "2 • chezmoi"         "$(label_of "$out" wA:t2)"
check "agent pane takes the agent name"      "3 • claude"          "$(label_of "$out" wA:t3)"
check "program title is capped and trimmed"  "4 • Add number prefixes" "$(label_of "$out" wA:t4)"
check "program title kept whole"             "1 • Yazi: herdr"     "$(label_of "$out" wB:t1)"
check "manual name kept, number applied"     "2 • agent"           "$(label_of "$out" wB:t2)"
check "null title is left alone"             ""                    "$(label_of "$out" wB:t3)"
check "ignored command is left alone"        ""                    "$(label_of "$out" wB:t4)"

check "manual tab is not claimed in state" \
  "null" "$(jq -r '.state["wB:t2"] // "null"' <<<"$out")"
check "auto tab is claimed in state" \
  "herdr" "$(jq -r '.state["wA:t1"] // "null"' <<<"$out")"

# An owned tab already carrying its label needs no rename.
out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "1 • herdr"')
check "owned tab with a current label is not renamed" \
  "" "$(label_of "$out" wA:t1)"

# A tab the user renamed away from its stored base becomes manual: name kept, number applied.
out=$(run '{"wA:t1":"herdr"}' '.result.snapshot.tabs[0].label = "mine"')
check "user rename is respected"   "1 • mine" "$(label_of "$out" wA:t1)"
check "user rename drops ownership" "null"    "$(jq -r '.state["wA:t1"] // "null"' <<<"$out")"

# Renaming a tab back to a bare number hands it back, even with stale state.
out=$(run '{"wA:t1":"mine"}' '.result.snapshot.tabs[0].label = "1"')
check "bare number hands the tab back" "1 • herdr" "$(label_of "$out" wA:t1)"

# An ignored command must not clobber a name this plugin already owns.
out=$(run '{"wB:t4":"cargo"}' '.result.snapshot.tabs[7].label = "4 • cargo"')
check "ignored command keeps the owned name" "" "$(label_of "$out" wB:t4)"

exit $fail
