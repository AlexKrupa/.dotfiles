#!/usr/bin/env bash
# Checks `sample` with a real test daemon in a temporary folder, and no herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
sample=$here/sample
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
export SAMPLE_ROOT=$tmp/root SAMPLE_STATE=$tmp/state SAMPLE_NO_HERDR=1
trap '"$sample" stop >/dev/null 2>&1; rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

has() { # has <text>, stdin: the text
  if grep -q -- "$1"; then echo yes; else echo no; fi
}

"$sample" status >/dev/null 2>"$tmp/err"
check "status with no daemon: exit 1" 1 "$?"
check "status with no daemon: names sample start" yes "$(has 'sample start' <"$tmp/err")"

mkdir -p "$SAMPLE_STATE/watchd"
sleep 30 &
echo "$!" >"$SAMPLE_STATE/watchd/daemon.pid"
"$sample" status >/dev/null 2>"$tmp/err"
check "status with a daemon of another binary: exit 1" 1 "$?"
check "status with a daemon of another binary: names sample start" yes \
  "$(has 'sample start' <"$tmp/err")"
kill "$!"
rm "$SAMPLE_STATE/watchd/daemon.pid"

"$sample" start >"$tmp/start.log" 2>&1 || { cat "$tmp/start.log"; echo "FAIL sample start"; exit 1; }

"$sample" check hub >"$tmp/check.log" 2>&1
code=$?
check "check hub: exit 0" 0 "$code"
[ "$code" = 0 ] || cat "$tmp/check.log"

"$sample" run hub >/dev/null && "$sample" next >/dev/null && "$sample" next >/dev/null
"$sample" next >/dev/null 2>&1
check "next after the last step: exit 1" 1 "$?"
check "next after the last step: the step stays" "hub 3" "$(cat "$SAMPLE_STATE/step")"

"$sample" run hub 2 >/dev/null
check "run to step 2: the step is 2" "hub 2" "$(cat "$SAMPLE_STATE/step")"

"$sample" run hub 4 >/dev/null 2>"$tmp/err"
check "run to a step that is not there: exit 1" 1 "$?"
check "run to a step that is not there: names the step" yes "$(has 'hub has no step 4' <"$tmp/err")"

"$sample" run hub >/dev/null
"$sample" back >/dev/null 2>&1
check "back at step 1: exit 1" 1 "$?"
check "back at step 1: the step stays" "hub 1" "$(cat "$SAMPLE_STATE/step")"

for scenario in branch stack review errors daemon; do
  "$sample" check "$scenario" >"$tmp/check.log" 2>&1
  code=$?
  check "check $scenario: exit 0" 0 "$code"
  [ "$code" = 0 ] || cat "$tmp/check.log"
done

# live_sub <role>: yes if the test daemon has an agent record of the role with a live session.
live_sub() {
  local key pid
  key=$(source "$here/lib.sh" && key_of "$1")
  pid=$(cd "$SAMPLE_ROOT/repo" && "$SAMPLE_ROOT/bin/watchd" debug state \
    | jq -r --arg key "$key" '.subs[$key].session_pid // empty')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo yes; else echo no; fi
}
"$sample" run branch >/dev/null && "$sample" next >/dev/null
check "branch-watching: a live agent record" yes "$(live_sub branch)"
"$sample" run errors >/dev/null && "$sample" next >/dev/null
check "check-error: no live agent record" no "$(live_sub branch)"
"$sample" run daemon >/dev/null && "$sample" next >/dev/null
check "migration: the version 1 worktree state loads" mine \
  "$(cd "$SAMPLE_ROOT/repo" && "$SAMPLE_ROOT/bin/watchd" debug state \
    | jq -r --arg path "$SAMPLE_ROOT/repo-branch" '.worktrees[$path].kind')"

mkdir -p "$tmp/scenarios/lost/01-lost"
echo 'printf "{}\n" >"$SAMPLE_STATE/engine/nobody.jsonl"' >"$tmp/scenarios/lost/01-lost/step.sh"
SAMPLE_SCENARIOS=$tmp/scenarios "$sample" run lost >/dev/null 2>"$tmp/err"
check "events of a key with no target: exit 1" 1 "$?"
check "events of a key with no target: names the key" yes \
  "$(has 'events not taken: nobody' <"$tmp/err")"

# A fake watcher with the process tree of `watch.sh ensure`: lockf, its child shell, and a child of
# that shell.
mkdir -p "$SAMPLE_STATE/herdr-watch"
lockf -s -k -t 0 "$SAMPLE_STATE/herdr-watch/watch.lock" bash -c 'sleep 4321 & wait' &
for _ in $(seq 20); do pgrep -f 'sleep 4321' >/dev/null && break; sleep 0.1; done
"$sample" stop >/dev/null 2>&1
check "stop: no process of the watcher stays" '' "$(pgrep -f 'sleep 4321')"

exit "$fail"
