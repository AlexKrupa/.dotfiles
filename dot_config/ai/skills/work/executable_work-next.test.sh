#!/usr/bin/env bash
# Checks work-next.sh with a fake herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/work-next.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: logs each call on one line, with "|" for newlines in the arguments.
# MOCK_WAIT_FAIL=1 makes `agent wait` fail.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s' "$*" | tr '\n' '|' >>"$MOCK_LOG"; echo >>"$MOCK_LOG"
if [ "$1 $2" = "agent wait" ] && [ -n "${MOCK_WAIT_FAIL:-}" ]; then exit 1; fi
echo '{}'
EOF
chmod +x "$tmp/bin/herdr"
export PATH="$tmp/bin:$PATH" MOCK_LOG="$tmp/calls.log"

: >"$MOCK_LOG"
printf '%s' $'ABC-2\n\nFix `x` in "$HOME"' | "$script" wL:p1 ABC-1/old >/dev/null 2>&1; code=$?
check "exit 0" 0 "$code"
check "calls in order" \
  "herdr agent wait wL:p1 --until idle --until done --timeout 600000
herdr agent prompt wL:p1 /clear ABC-1/old
herdr agent prompt wL:p1 ABC-2||Fix \`x\` in \"\$HOME\"" \
  "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
MOCK_WAIT_FAIL=1 "$script" wL:p1 ABC-1/old <<<"p" >/dev/null 2>&1; code=$?
check "wait fails: exit 1" 1 "$code"
check "wait fails: no prompt" "" "$(grep 'agent prompt' "$MOCK_LOG")"

: >"$MOCK_LOG"
"$script" wL:p1 ABC-1/old </dev/null >/dev/null 2>&1; code=$?
check "no prompt text: exit 1" 1 "$code"
check "no prompt text: no herdr call" "" "$(cat "$MOCK_LOG")"

exit $fail
