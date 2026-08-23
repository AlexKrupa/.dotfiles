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

export TAB_NAME_SNAPSHOT="$PWD/snapshot.json"
export TAB_NAME_STATE="$tmp/state.json"
export TAB_NAME_DRY=1
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
  "workspace wA -> 1" "$(grep '^workspace wA' <<<"$out")"
check "sweep leaves a workspace whose token already matches" \
  "" "$(grep '^workspace wB' <<<"$out")"
check "sweep clears the token of a workspace past the ninth slot" \
  "workspace wZ -> " "$(grep '^workspace wZ' <<<"$out")"
check "sweep numbers an agent from its position in the list" \
  "pane wA:p3 -> 1" "$(grep '^pane wA:p3' <<<"$out")"
check "sweep corrects an agent token that moved slot" \
  "pane wB:p9 -> 2" "$(grep '^pane wB:p9' <<<"$out")"

check "sweep created the state file" \
  "herdr" "$(jq -r '.["wA:t1"] // "null"' "$TAB_NAME_STATE")"
check "sweep did not claim the manual tab" \
  "null" "$(jq -r '.["wB:t2"] // "null"' "$TAB_NAME_STATE")"

# TAB_NAME_DRY never applies the renames, so a second sweep prints the same ones. Only the
# state file must stay stable.
before=$(cat "$TAB_NAME_STATE")
../watch.sh sweep >/dev/null
check "state is stable across sweeps" "$before" "$(cat "$TAB_NAME_STATE")"

check "missing state file is not fatal" "0" "$(
  rm -f "$TAB_NAME_STATE"; ../watch.sh sweep >/dev/null 2>&1; echo $?)"

exit $fail
