#!/usr/bin/env bash
# Checks watch.sh sweep: state file round-tripping and rename output, with no herdr
# process involved. Run: tests/test-sweep.sh
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

out=$(../watch.sh sweep)

check "sweep prints a rename for the idle tab" \
  "rename wA:t1 -> 1 • herdr" "$(grep '^rename wA:t1' <<<"$out")"
check "sweep prints no rename for the null-title tab" \
  "" "$(grep '^rename wB:t3' <<<"$out")"
check "sweep created the state file" \
  "herdr" "$(jq -r '.["wA:t1"] // "null"' "$TAB_NAME_STATE")"
check "sweep did not claim the manual tab" \
  "null" "$(jq -r '.["wB:t2"] // "null"' "$TAB_NAME_STATE")"

# A second sweep over an unchanged session must still print the same renames, because
# TAB_NAME_DRY never applies them - the state file is what must stay stable.
before=$(cat "$TAB_NAME_STATE")
../watch.sh sweep >/dev/null
check "state is stable across sweeps" "$before" "$(cat "$TAB_NAME_STATE")"

check "missing state file is not fatal" "0" "$(
  rm -f "$TAB_NAME_STATE"; ../watch.sh sweep >/dev/null 2>&1; echo $?)"

exit $fail
