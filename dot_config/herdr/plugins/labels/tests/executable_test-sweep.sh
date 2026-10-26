#!/usr/bin/env bash
# Checks watch.sh sweep with no herdr process involved.
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

export LABELS_SNAPSHOT="$PWD/snapshot.json"
export LABELS_STATE="$tmp/state.json"
export LABELS_DRY=1
# `pane process-info` is a real call in a sweep, so mocks/herdr answers it from a fixture.
export PATH="$PWD/mocks:$PATH"
export HOME=/Users/tester

out=$(../watch.sh sweep)

check "sweep prints a rename for the idle tab" \
  "tab wA:t1 -> 1 • herdr" "$(grep '^tab wA:t1' <<<"$out")"
check "sweep prints a rename for the lazygit tab" \
  "tab wA:t4 -> 4 • lazygit" "$(grep '^tab wA:t4' <<<"$out")"
check "sweep prints no rename for the tab with no reading" \
  "" "$(grep '^tab wB:t3' <<<"$out")"
check "sweep numbers a workspace from its own slot" \
  "workspace wA -> idx=1" "$(grep '^workspace wA' <<<"$out")"
check "sweep leaves a workspace whose token already matches" \
  "" "$(grep '^workspace wB' <<<"$out")"
check "sweep clears the token of a workspace past the ninth slot" \
  "workspace wZ -> idx=" "$(grep '^workspace wZ' <<<"$out")"
check "sweep ranks an agent" \
  "pane wA:p3 -> ord=001 rank=1 dot_unknown=·" "$(grep '^pane wA:p3' <<<"$out")"
check "sweep ranks the next agent and clears its old idx" \
  "pane wB:p9 -> ord=002 rank=2 idx= dot_unknown=·" "$(grep '^pane wB:p9' <<<"$out")"

check "sweep created the state file" \
  "herdr" "$(jq -r '.tabs["wA:t1"] // "null"' "$LABELS_STATE")"
check "sweep did not claim the manual tab" \
  "null" "$(jq -r '.tabs["wB:t2"] // "null"' "$LABELS_STATE")"

# LABELS_DRY never applies the renames, so a second sweep prints the same ones. Only the
# state file must stay stable.
before=$(cat "$LABELS_STATE")
../watch.sh sweep >/dev/null
check "state is stable across sweeps" "$before" "$(cat "$LABELS_STATE")"

check "missing state file is not fatal" "0" "$(
  rm -f "$LABELS_STATE"; ../watch.sh sweep >/dev/null 2>&1; echo $?)"

# A real apply, against the mock: one call per pane or workspace, with every token in it.
log="$tmp/calls.log"
LABELS_DRY='' HERDR_MOCK_LOG="$log" LABELS_STATE="$tmp/applied.json" \
  ../watch.sh sweep >/dev/null
check "apply sets and clears pane tokens in one call" \
  "pane report-metadata wB:p9 --source labels --token ord=002 --token rank=2 --clear-token idx --token dot_unknown=·" \
  "$(grep '^pane report-metadata wB:p9' "$log")"
jq '.result.snapshot.panes += [{pane_id: "wA:p6", tab_id: "wA:t3", agent: "codex",
  tokens: {session: "Review the diff"}}]' snapshot.json >"$tmp/two-agents.json"
jq '.result.snapshot.panes[-1].label = "mine"' "$tmp/two-agents.json" >"$tmp/labeled.json"
titles_log="$tmp/titles.log"
LABELS_SNAPSHOT="$tmp/two-agents.json" LABELS_DRY='' HERDR_MOCK_LOG="$titles_log" \
  LABELS_STATE="$tmp/titled.json" ../watch.sh sweep >/dev/null
check "apply sets a pane title" \
  "pane report-metadata wA:p6 --source labels --title Review the diff" \
  "$(grep '^pane report-metadata wA:p6' "$titles_log")"
LABELS_SNAPSHOT="$tmp/labeled.json" LABELS_DRY='' HERDR_MOCK_LOG="$titles_log" \
  LABELS_STATE="$tmp/titled.json" ../watch.sh sweep >/dev/null
check "apply clears a pane title" \
  "pane report-metadata wA:p6 --source labels --clear-title" \
  "$(grep '^pane report-metadata wA:p6' "$titles_log" | tail -n 1)"
check "apply clears a workspace token in one call" \
  "workspace report-metadata wZ --source labels --clear-token idx" \
  "$(grep '^workspace report-metadata wZ' "$log")"

jq '.result.snapshot.workspaces[1].tokens.watch_kind = "mine"' snapshot.json >"$tmp/watched.json"
echo '{"mine": "M"}' >"$tmp/glyphs.json"
check "sweep puts the glyphs of the table in idx" "workspace wB -> idx=2 M" "$(
  LABELS_SNAPSHOT="$tmp/watched.json" LABELS_GLYPHS="$tmp/glyphs.json" ../watch.sh sweep \
    | grep '^workspace wB')"
echo 'not json' >"$tmp/glyphs.json"
check "a bad glyph table shows no glyphs" "workspace wA -> idx=1" "$(
  LABELS_SNAPSHOT="$tmp/watched.json" LABELS_GLYPHS="$tmp/glyphs.json" ../watch.sh sweep 2>&1 \
    | grep '^workspace wA')"

# alive_after <seconds> <env argument>...: "alive" if the watcher still runs after the time.
alive_after() {
  local seconds=$1 pid result=gone
  shift
  env "$@" ../watch.sh watch >/dev/null 2>&1 &
  pid=$!
  sleep "$seconds"
  kill -0 "$pid" 2>/dev/null && result=alive
  pkill -P "$pid" 2>/dev/null
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "$result"
}
check "the watcher outlives a socket that it cannot reach" \
  alive "$(alive_after 3 HERDR_SOCKET_PATH="$tmp/none.sock")"
check "the watcher outlives a start with no socket path" \
  alive "$(alive_after 3 -u HERDR_SOCKET_PATH)"

exit $fail
