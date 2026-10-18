#!/usr/bin/env bash
# Checks handoff.sh with a real git repo, fake herdr, and a fake herdr-after-turn.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/handoff.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

mkdir -p "$tmp/bin" "$tmp/home"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pane current") echo '{"result":{"pane":{"pane_id":"wL:p1"}}}' ;;
esac
EOF
# Fake helper: logs its arguments and the prompt on stdin.
cat >"$tmp/after-turn" <<'EOF'
#!/bin/sh
{ printf 'args %s\n' "$*"; printf 'prompt '; cat; echo; } >"$MOCK_LOG"
EOF
chmod +x "$tmp/bin/herdr" "$tmp/after-turn"

git init -q "$tmp/my-repo"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" MOCK_LOG="$tmp/log"
export HANDOFF_AFTER_TURN="$tmp/after-turn" HANDOFF_DATE=2026-10-18-1430
cd "$tmp/my-repo" || exit 1

out=$("$script" path 'Retry logic!' ABC-123)
check "path: ticket and slug" \
  "$tmp/home/.ai/my-repo/handoffs/2026-10-18-1430-ABC-123-retry-logic.md" "$out"
check "path: folder exists" yes "$([ -d "$tmp/home/.ai/my-repo/handoffs" ] && echo yes)"

out=$("$script" path 'retry logic')
check "path: no ticket" "$tmp/home/.ai/my-repo/handoffs/2026-10-18-1430-retry-logic.md" "$out"

"$script" path '!!' >/dev/null 2>&1
check "path: topic with no letters fails" 1 "$?"

file="$tmp/home/.ai/my-repo/handoffs/2026-10-18-1430-retry-logic.md"
"$script" refresh "$file" >/dev/null 2>&1
check "refresh: missing file fails" 1 "$?"

echo handoff >"$file"
out=$(HERDR_ENV= "$script" refresh "$file" 2>&1)
check "refresh: outside herdr exits 4" 4 "$?"
check "refresh: outside herdr prints the line" "Continue from \`$file\`." "$out"

rm -f "$MOCK_LOG"
HERDR_ENV=1 NONO_CAP_FILE= "$script" refresh "$file" >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$MOCK_LOG" ] && break; sleep 0.1; done
check "refresh: helper args" "args wL:p1 --clear 2026-10-18-1430-retry-logic" \
  "$(sed -n 1p "$MOCK_LOG")"
check "refresh: prompt" "prompt Continue from \`$file\`." "$(sed -n 2p "$MOCK_LOG")"

rm -f "$MOCK_LOG"
HERDR_ENV=1 NONO_CAP_FILE=/cap "$script" refresh "$file" >/dev/null
check "refresh: nono runs the helper in the foreground" \
  "args wL:p1 --clear 2026-10-18-1430-retry-logic" "$(sed -n 1p "$MOCK_LOG" 2>/dev/null)"

exit $fail
