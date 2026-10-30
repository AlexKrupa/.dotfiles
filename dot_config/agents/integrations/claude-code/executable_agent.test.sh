#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/agent.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Runs the adapter. Sets $out, $err, and $code.
run() {
  out=$("$script" "$@" 2>"$tmp/err"); code=$?
  err=$(cat "$tmp/err")
}

run kind
check "kind: herdr kind" "0 claude" "$code $out"

run clear 'ABC-1/old'
check "clear: slash command with the title" "0 /clear ABC-1/old" "$code $out"

run effort medium
check "effort: slash command with the level" "0 /effort medium" "$code $out"

run rename '[AB-17] Add `f` for $HOME'
check "rename: title word for word" '0 /rename [AB-17] Add `f` for $HOME' "$code $out"

run start-args '[ABC-7] Add: x'
check "start-args: name and title on two lines" $'0 --name\n[ABC-7] Add: x' "$code $out"

run start-args 'T' --effort high --model opus
check "start-args: flags in the given order" $'0 --name\nT\n--effort\nhigh\n--model\nopus' \
  "$code $out"

run start-args '-x'
check "start-args: a title with a leading - is the title" $'0 --name\n-x' "$code $out"

run model opus
check "unknown action: exit 3, no stdout" "3 " "$code $out"
check "unknown action: stderr names the action" "claude-code: no model action" "$err"

for args in "" "rename" "rename a b" "start-args ''" "start-args T --dangerous" \
  "start-args T --model"; do
  eval "run $args"
  check "usage error '$args': exit 2, no stdout" "2 " "$code $out"
done

exit $fail
