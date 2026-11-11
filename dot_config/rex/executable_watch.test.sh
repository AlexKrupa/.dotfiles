#!/usr/bin/env bash
# Checks watch.sh with a fake watchd and the shared notification rules.
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
} | jq -c -s 'to_entries[] | if .value.type == "sidebar" then .value else .value + {id: .key} end' \
  >"$tmp/lines"
# Written while the pane had no connection: only `follow --after 5` gives it.
line comment carol 'Missed?' | jq -c '. + {id: 6}' >"$tmp/missed"

# Fake watchd: logs each call. The first `follow` prints the lines and ends, as the follow of a
# daemon that restarts. A later `follow --after 5` prints the missed line.
cat >"$tmp/watchd" <<'EOF'
#!/bin/sh
[ "$1" = follow ] || exit 2
echo "$*" >>"$MOCK_CALLS"
if [ ! -e "$MOCK_DONE" ]; then cat "$MOCK_LINES"; : >"$MOCK_DONE"; exit 0; fi
if [ "$*" = "follow --after 5" ]; then cat "$MOCK_MISSED"; fi
exec sleep 30
EOF
chmod +x "$tmp/watchd"

WATCHD=$tmp/watchd MOCK_LINES=$tmp/lines MOCK_MISSED=$tmp/missed MOCK_DONE=$tmp/done \
  MOCK_CALLS=$tmp/calls "$here/watch.sh" >"$tmp/out" 2>&1 &
pid=$!
for _ in $(seq 50); do [ "$(grep -c $'\a' "$tmp/out")" -ge 5 ] && break; sleep 0.1; done

check "one OSC 9 notification for each event, the route line gives the opened one, the missed line after the reconnect" \
  "$(printf '%s\n' \
    $'\e]9;Add retry banner: @bob commented: "Can we reuse?"\a' \
    $'\e]9;Add retry banner: @anna approved\a' \
    $'\e]9;Update foo: New dependency bump. Bump agent started.\a' \
    $'\e]9;Hub: Watch stopped: auth failed\a' \
    $'\e]9;Add retry banner: @carol commented: "Missed?"\a')" \
  "$(grep -o $'\e\\][^\a]*\a' "$tmp/out")"
check "after the daemon closes the socket, the pane follows after the last id" \
  "follow
follow --after 5" "$(cat "$tmp/calls")"

exit $fail
