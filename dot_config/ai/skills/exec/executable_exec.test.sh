#!/usr/bin/env bash
# Checks exec.sh with a fake herdr and a fake herdr-after-turn.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/exec.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

mkdir -p "$tmp/bin" "$tmp/plans"
cat >"$tmp/bin/herdr" <<'EOF'
#!/bin/sh
echo '{"result":{"pane":{"pane_id":"w1:p2"}}}'
EOF
# Fake herdr-after-turn.sh: writes its arguments and stdin to $MOCK_AFTER.
cat >"$tmp/bin/after" <<'EOF'
#!/bin/sh
{ printf '%s\n' "$@"; echo ---; cat; } >"$MOCK_AFTER.tmp"
mv "$MOCK_AFTER.tmp" "$MOCK_AFTER"
EOF
chmod +x "$tmp/bin/herdr" "$tmp/bin/after"
export PATH="$tmp/bin:$PATH" HERDR_AFTER_TURN="$tmp/bin/after" MOCK_AFTER="$tmp/after.out" \
  TMPDIR="$tmp" HERDR_ENV=1
plan="$tmp/plans/2026-09-30-foo.md"
echo '# Foo plan' >"$plan"

# got: waits up to 5 s for the fake herdr-after-turn.sh, then prints what it got.
got() {
  for _ in $(seq 50); do [ -f "$MOCK_AFTER" ] && break; sleep 0.1; done
  cat "$MOCK_AFTER" 2>/dev/null; rm -f "$MOCK_AFTER"
}

"$script" --fresh subagent medium "$plan" >/dev/null 2>&1; code=$?
check "fresh subagent: exit 0" 0 "$code"
check "fresh subagent: pane, clear name, effort, plan command" \
  "w1:p2
--clear
2026-09-30-foo
/effort medium
---
/superpowers:subagent-driven-development $plan" "$(got)"

"$script" native high "$plan" >/dev/null 2>&1; code=$?
check "same session native: exit 0" 0 "$code"
check "same session native: no clear" \
  "w1:p2
/effort high
---
/superpowers:executing-plans $plan" "$(got)"

cd "$tmp"
"$script" --fresh native high plans/2026-09-30-foo.md >/dev/null 2>&1; code=$?
check "relative path: exit 0" 0 "$code"
check "relative path: absolute path in plan command" \
  "/superpowers:executing-plans $plan" "$(got | tail -1)"

"$script" native high "$tmp/plans/none.md" >/dev/null 2>&1; code=$?
check "no plan file: exit 1" 1 "$code"
"$script" inline high "$plan" >/dev/null 2>&1; code=$?
check "bad mode: exit 1" 1 "$code"
"$script" native huge "$plan" >/dev/null 2>&1; code=$?
check "bad effort: exit 1" 1 "$code"
HERDR_ENV= "$script" native high "$plan" >/dev/null 2>&1; code=$?
check "not in herdr: exit 1" 1 "$code"
check "errors: no herdr-after-turn.sh" "" "$(got)"

exit $fail
