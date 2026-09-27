#!/usr/bin/env bash
# Runs no herdr, nvim, ps or stty commands - tests/mocks stands in for all four - so it is
# safe in any pane.
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

export PATH="$PWD/mocks:$PATH"
export MOCK_LOG=$tmp/log
export NSSF_TRIES=4 NSSF_INTERVAL=0.05

nudge='pane resize --pane w1:p2 --direction left --amount 0.01
pane resize --pane w1:p2 --direction right --amount 0.01'

# watch <attached> <ui> <pty> -> the logged herdr resizes
watch() {
  : >"$MOCK_LOG"
  MOCK_ATTACHED=$1 MOCK_UI=$2 MOCK_PTY=$3 ../fix.sh watch w1:p2
  cat "$MOCK_LOG"
}

# created <label> <ui> -> the logged herdr resizes, once the detached watch is done
created() {
  : >"$MOCK_LOG"
  HERDR_PLUGIN_EVENT_JSON=$(jq -cn --arg label "$1" \
      '{event: "pane_created", data: {pane: {pane_id: "w1:p2", label: $label}}}') \
    MOCK_ATTACHED=1 MOCK_UI=$2 MOCK_PTY="61 95" ../fix.sh on-created
  sleep 0.5
  cat "$MOCK_LOG"
}

check "nvim wider than its pty is nudged"      "$nudge" "$(watch 1 "63 195" "61 95")"
check "nvim at the pty size is left alone"     ""       "$(watch 1 "61 95" "61 95")"
check "a pane with no nvim client is skipped"  ""       "$(watch 0 "63 195" "61 95")"
check "nvim with no UI yet is skipped"         ""       "$(watch 1 "" "61 95")"

check "a new sidebar is watched"               "$nudge" "$(created "nvim sidebar" "63 195")"
check "a new pane of another kind is ignored"  ""       "$(created "shell" "63 195")"

exit $fail
