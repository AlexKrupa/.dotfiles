#!/usr/bin/env bash
# Checks watch.sh with a fake watchd and the notify.jq of the herdr watch plugin.
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

now=$(date +%s)
line() { # line <kind> <actor> <detail>: one event line of the log
  jq -nc --arg k "$1" --arg a "$2" --arg d "$3" --argjson t "$now" '{time: $t, round: "r1",
    type: "event", slug: "app", key: "app-x", mode: "author",
    event: {kind: $k, iid: 5, title: "Add retry banner", url: "u", actor: $a, detail: $d,
      branch: "ABC-1/retry"}, sound: "request"}'
}
{
  echo '{"type":"sidebar","last_id":0,"subs":[],"worktrees":{},"engine_needs":{}}'
  line comment bob 'Can we reuse?'
  line approved anna approved
  jq -nc --argjson t "$now" '{time: $t, round: "r2", type: "event", slug: "app", key: "app",
    mode: "hub", event: {kind: "opened", iid: 61, title: "Update foo", url: "u",
    actor: "renovate-bot", detail: "opened", branch: "renovate/foo"}, sound: "none"}'
  jq -nc --argjson t "$now" '{time: $t, type: "route", slug: "app", key: "app", iid: 61,
    action: "bump"}'
  echo '{"type":"stopped","title":"Hub","error":"auth failed"}'
} >"$tmp/lines"

# Fake watchd: prints the lines on the first `follow`, then nothing.
cat >"$tmp/watchd" <<'EOF'
#!/bin/sh
[ "$1" = follow ] || exit 2
if [ ! -e "$MOCK_DONE" ]; then cat "$MOCK_LINES"; : >"$MOCK_DONE"; fi
exec sleep 30
EOF
chmod +x "$tmp/watchd"

WATCHD=$tmp/watchd MOCK_LINES=$tmp/lines MOCK_DONE=$tmp/done "$here/watch.sh" >"$tmp/out" 2>&1 &
pid=$!
for _ in $(seq 50); do [ "$(grep -c $'\a' "$tmp/out")" -ge 4 ] && break; sleep 0.1; done

check "one OSC 9 notification for each event, the route line gives the opened one" \
  "$(printf '%s\n' \
    $'\e]9;Add retry banner: @bob commented: "Can we reuse?"\a' \
    $'\e]9;Add retry banner: @anna approved\a' \
    $'\e]9;Update foo: New dependency bump. Bump agent started.\a' \
    $'\e]9;Hub: Watch stopped: auth failed\a')" \
  "$(grep -o $'\e\\][^\a]*\a' "$tmp/out")"

exit $fail
