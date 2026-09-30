#!/usr/bin/env bash
# Checks exec-fresh.sh with a fake herdr and a fake herdr-clear-session.sh.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/exec-fresh.sh"
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
# Fake herdr-clear-session.sh: writes its arguments and stdin to $MOCK_CLEAR.
cat >"$tmp/bin/clear" <<'EOF'
#!/bin/sh
{ printf '%s\n' "$@"; echo ---; cat; } >"$MOCK_CLEAR.tmp"
mv "$MOCK_CLEAR.tmp" "$MOCK_CLEAR"
EOF
chmod +x "$tmp/bin/herdr" "$tmp/bin/clear"
export PATH="$tmp/bin:$PATH" HERDR_CLEAR_SESSION="$tmp/bin/clear" MOCK_CLEAR="$tmp/clear.out" \
  TMPDIR="$tmp" HERDR_ENV=1
plan="$tmp/plans/2026-09-30-foo.md"
echo '# Foo plan' >"$plan"

# got: waits up to 5 s for the fake herdr-clear-session.sh, then prints what it got.
got() {
  for _ in $(seq 50); do [ -f "$MOCK_CLEAR" ] && break; sleep 0.1; done
  cat "$MOCK_CLEAR" 2>/dev/null; rm -f "$MOCK_CLEAR"
}

"$script" subagent medium "$plan" >/dev/null 2>&1; code=$?
check "subagent: exit 0" 0 "$code"
check "subagent: pane, name, effort, plan command" \
  "w1:p2
2026-09-30-foo
/effort medium
---
/superpowers:subagent-driven-development $plan" "$(got)"

cd "$tmp"
"$script" native high plans/2026-09-30-foo.md >/dev/null 2>&1; code=$?
check "native, relative path: exit 0" 0 "$code"
check "native, relative path: absolute path in plan command" \
  "w1:p2
2026-09-30-foo
/effort high
---
/superpowers:executing-plans $plan" "$(got)"

"$script" native high "$tmp/plans/none.md" >/dev/null 2>&1; code=$?
check "no plan file: exit 1" 1 "$code"
"$script" inline high "$plan" >/dev/null 2>&1; code=$?
check "bad mode: exit 1" 1 "$code"
"$script" native huge "$plan" >/dev/null 2>&1; code=$?
check "bad effort: exit 1" 1 "$code"
HERDR_ENV= "$script" native high "$plan" >/dev/null 2>&1; code=$?
check "not in herdr: exit 1" 1 "$code"
check "errors: no clear" "" "$(got)"

exit $fail
