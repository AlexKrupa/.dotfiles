#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/context.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# has <text> <part>: prints yes if the text has the part.
has() { [[ $1 == *"$2"* ]] && echo yes || echo no; }

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
export WATCHD="$tmp/bin/watchd" FAKE_LOG="$tmp/calls.log"
export CLAUDE_CODE_SESSION_ID=session-1

# run <env assignments...>: runs context.sh with a SessionStart compact input, sets code, stdout,
# and stderr.
run() {
  printf '{"session_id":"session-1","hook_event_name":"SessionStart","source":"compact"}' \
    | env "$@" "$script" >"$tmp/stdout" 2>"$tmp/stderr"
  code=$?
  stdout=$(cat "$tmp/stdout")
  stderr=$(cat "$tmp/stderr")
}

fresh() { : >"$FAKE_LOG"; }

fresh
watches=$'hub\t/repos/app\t-\nreview\t/repos/app\t5'
run FAKE_OUT="$watches"
context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$stdout")
check "watches: exit 0" 0 "$code"
check "watches: no stderr" "" "$stderr"
check "watches: runs watches --session <id>" "watches --session session-1" "$(cat "$FAKE_LOG")"
check "watches: SessionStart output" SessionStart \
  "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$stdout")"
check "watches: the context has the watches" yes "$(has "$context" "$watches")"
check "watches: the context has the runner file" yes \
  "$(has "$context" "$here/watch-runner.md")"
check "watches: the context has the error rule" yes "$(has "$context" 'watchd error:')"

fresh
run
check "no watches: exit 0" 0 "$code"
check "no watches: no stdout" "" "$stdout"

fresh
run FAKE_CODE=1 FAKE_ERR="watchd: watches needs --session"
check "watchd fails: exit 0" 0 "$code"
check "watchd fails: no stdout" "" "$stdout"
check "watchd fails: no stderr" "" "$stderr"

fresh
run -u CLAUDE_CODE_SESSION_ID
check "no CLAUDE_CODE_SESSION_ID: exit 0" 0 "$code"
check "no CLAUDE_CODE_SESSION_ID: no stdout" "" "$stdout"
check "no CLAUDE_CODE_SESSION_ID: watchd not started" "" "$(cat "$FAKE_LOG")"

exit "$fail"
