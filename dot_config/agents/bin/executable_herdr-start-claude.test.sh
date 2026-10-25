#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/herdr-start-claude"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: writes each argument in brackets to $tmp/herdr.log, exits $MOCK_EXIT.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf '[%s]' "$@" >"$MOCK_LOG"
exit "${MOCK_EXIT:-0}"
EOF
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/herdr.log"

# run <args...>: sets $code, $err, and $log (empty if herdr did not run).
run() {
  rm -f "$MOCK_LOG"
  "$script" "$@" 2>"$tmp/err" && code=0 || code=$?
  err=$(cat "$tmp/err")
  log=$(cat "$MOCK_LOG" 2>/dev/null)
}

run abc-1-fix w1:p2 '[ABC-1] Fix it' high
check "effort: exit 0" 0 "$code"
check "effort: claude with name and effort" \
  "[agent][start][abc-1-fix][--kind][claude][--pane][w1:p2][--][--name][[ABC-1] Fix it][--effort][high]" \
  "$log"

run abc-1-fix w1:p2 'Fix it'
check "no effort: claude with name only" \
  "[agent][start][abc-1-fix][--kind][claude][--pane][w1:p2][--][--name][Fix it]" "$log"

MOCK_EXIT=1 run abc-1-fix w1:p2 'Fix it'
check "herdr fails: exit code of herdr" 1 "$code"

run -x w1:p2 t
check "name starts with -: exit 2, no herdr" "2 " "$code $log"
run x --pane t
check "pane starts with -: exit 2, no herdr" "2 " "$code $log"
run x w1:p2 --model
check "title starts with -: exit 2, no herdr" "2 " "$code $log"
run x w1:p2 ''
check "empty title: exit 2, no herdr" "2 " "$code $log"
run x w1:p2 t huge
check "bad effort: exit 2, no herdr" "2 " "$code $log"
check "bad effort: error text" \
  "herdr-start-claude: effort must be low, medium, high, xhigh, or max, not 'huge'" "$err"
run x w1:p2
check "too few arguments: exit 2, no herdr" "2 " "$code $log"
run x w1:p2 t high --dangerously-skip-permissions
check "too many arguments: exit 2, no herdr" "2 " "$code $log"

exit $fail
