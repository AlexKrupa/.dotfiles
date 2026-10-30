#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/wait.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake watchd: logs its arguments, then answers from FAKE_OUT (stdout), FAKE_ERR (stderr),
# and FAKE_CODE (exit code).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/watchd" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
[ -z "${FAKE_OUT:-}" ] || printf '%s\n' "$FAKE_OUT"
[ -z "${FAKE_ERR:-}" ] || printf '%s\n' "$FAKE_ERR" >&2
exit "${FAKE_CODE:-0}"
FAKE
chmod +x "$tmp/bin/watchd"
export WATCHD="$tmp/bin/watchd" TMPDIR="$tmp" FAKE_LOG="$tmp/calls.log"
export CLAUDE_CODE_SESSION_ID=session-1 CLAUDE_PID=4242

# run <env assignments...>: runs wait.sh with the hook input of $tmp/stdin, sets code, stdout, and
# stderr.
run() {
  env "$@" "$script" <"$tmp/stdin" >"$tmp/stdout" 2>"$tmp/stderr"
  code=$?
  stdout=$(cat "$tmp/stdout")
  stderr=$(cat "$tmp/stderr")
}

fresh() { rm -rf "$tmp/watchd-wait" "$FAKE_LOG"; : >"$FAKE_LOG"; : >"$tmp/stdin"; }

fresh
run FAKE_CODE=0
check "exit 0, no output: exit 0" 0 "$code"
check "exit 0, no output: no stderr" "" "$stderr"
check "exit 0, no output: no stdout" "" "$stdout"
check "empty input: wait --session <id> --owner-pid <pid>, no rename flag" \
  "wait --session session-1 --owner-pid 4242" "$(cat "$FAKE_LOG")"

fresh
events=$'{"kind":"comment","key":"k","mode":"author"}\n{"kind":"merged","key":"k","mode":"author"}'
run FAKE_CODE=0 FAKE_OUT="$events"
check "exit 0, event lines: exit 2" 2 "$code"
check "exit 0, event lines: the lines on stderr" "$events" "$stderr"
check "exit 0, event lines: no stdout" "" "$stdout"

fresh
run FAKE_CODE=1 FAKE_ERR="token expired"
check "exit 1: exit 2" 2 "$code"
check "exit 1: error row on stderr" "watchd error: token expired" "$stderr"

run FAKE_CODE=1 FAKE_ERR="token expired"
check "exit 1 with the same text again: exit 0" 0 "$code"
check "exit 1 with the same text again: no stderr" "" "$stderr"

run FAKE_CODE=1 FAKE_ERR="network down"
check "exit 1 with a different text: exit 2" 2 "$code"
check "exit 1 with a different text: error row" "watchd error: network down" "$stderr"

CLAUDE_CODE_SESSION_ID=session-2 run FAKE_CODE=1 FAKE_ERR="network down"
check "the same text in another session: exit 2" 2 "$code"

fresh
run FAKE_CODE=1 FAKE_ERR="token expired"
run FAKE_CODE=0
run FAKE_CODE=1 FAKE_ERR="token expired"
check "exit 1, then exit 0, then the same text: exit 2" 2 "$code"
check "exit 1, then exit 0, then the same text: error row" "watchd error: token expired" "$stderr"

fresh
run FAKE_CODE=2 FAKE_ERR="unknown subcommand wait"
check "exit 2 of watchd (an old binary): exit 2" 2 "$code"
check "exit 2 of watchd (an old binary): error row" \
  "watchd error: unknown subcommand wait" "$stderr"

fresh
run FAKE_CODE=1
check "exit 1, no text: exit 2" 2 "$code"
check "exit 1, no text: error row with the code" "watchd error: exit code 1, no message" "$stderr"

args="wait --session session-1 --owner-pid 4242"
for source in startup resume compact fork; do
  fresh
  printf '{"session_id":"session-1","hook_event_name":"SessionStart","source":"%s"}' "$source" >"$tmp/stdin"
  run FAKE_CODE=0
  check "SessionStart source $source: no rename flag" "$args" "$(cat "$FAKE_LOG")"
done

fresh
printf '{"session_id":"session-1","hook_event_name":"SessionStart","source":"clear"}' >"$tmp/stdin"
run FAKE_CODE=0
check "SessionStart source clear: the rename flag" "$args --rename-owner-session" "$(cat "$FAKE_LOG")"

fresh
printf '{"session_id":"session-1","hook_event_name":"Stop","stop_hook_active":false}' >"$tmp/stdin"
run FAKE_CODE=0
check "Stop input: no rename flag" "$args" "$(cat "$FAKE_LOG")"

fresh
printf 'not json' >"$tmp/stdin"
run FAKE_CODE=0
check "input that is not JSON: exit 0" 0 "$code"
check "input that is not JSON: no stderr" "" "$stderr"
check "input that is not JSON: no rename flag" "$args" "$(cat "$FAKE_LOG")"

fresh
mkdir -p "$tmp/home/.local/bin"
cp "$tmp/bin/watchd" "$tmp/home/.local/bin/watchd"
run -u WATCHD HOME="$tmp/home" PATH=/usr/bin:/bin FAKE_CODE=0
check "no WATCHD: exit 0" 0 "$code"
check "no WATCHD: runs ~/.local/bin/watchd" "$args" "$(cat "$FAKE_LOG")"

fresh
env -u CLAUDE_CODE_SESSION_ID "$script" >"$tmp/stdout" 2>"$tmp/stderr"; code=$?
check "no CLAUDE_CODE_SESSION_ID: exit 0" 0 "$code"
check "no CLAUDE_CODE_SESSION_ID: no stderr" "" "$(cat "$tmp/stderr")"
check "no CLAUDE_CODE_SESSION_ID: watchd not started" "" "$(cat "$FAKE_LOG")"

fresh
env -u CLAUDE_PID "$script" >"$tmp/stdout" 2>"$tmp/stderr"; code=$?
check "no CLAUDE_PID: exit 0" 0 "$code"
check "no CLAUDE_PID: no stderr" "" "$(cat "$tmp/stderr")"
check "no CLAUDE_PID: watchd not started" "" "$(cat "$FAKE_LOG")"

exit "$fail"
