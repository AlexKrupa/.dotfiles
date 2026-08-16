#!/usr/bin/env bash
# Checks watch.sh decide against tests/agents.json. Runs no herdr commands, spawns no
# caffeinate and touches no real state, so it is safe in any pane. Run: tests/test.sh
set -u

cd "$(dirname "$0")" || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

export CAFFEINATE_STATE="$tmp"
export CAFFEINATE_GRACE=60

# run [jq-filter-to-mutate-the-fixture] -> the decision
run() {
  if [ -n "${1:-}" ]; then jq "$1" agents.json >"$tmp/agents.json"
  else cp agents.json "$tmp/agents.json"; fi
  CAFFEINATE_AGENTS="$tmp/agents.json" ../watch.sh decide
}

# This shell is alive, so a hold file naming it reads as a live assertion.
hold_alive() { printf '%s\n' "$$" >"$tmp/caffeinate.pid"; }
no_hold()    { rm -f "$tmp/caffeinate.pid"; }
stamp()      { [ -e "$tmp/idle-since" ] && echo yes || echo no; }

# Nothing else in the fixture works, so demoting the one working agent also checks that
# blocked never holds.
blocked='.result.agents[0].agent_status = "blocked"'

no_hold; rm -f "$tmp/idle-since"
check "a working agent asks for a hold" "hold" "$(run)"

hold_alive
check "an existing hold is not re-taken" "" "$(run)"

printf '%s\n' 0 >"$tmp/idle-since"
run >/dev/null
check "work clears a stale idle stamp" "no" "$(stamp)"

no_hold; rm -f "$tmp/idle-since"
check "blocked and idle alone do not hold" "" "$(run "$blocked")"
check "no hold means no idle stamp"        "no" "$(stamp)"

hold_alive; rm -f "$tmp/idle-since"
check "first quiet sweep only starts the clock" "" "$(run "$blocked")"
check "first quiet sweep wrote the stamp"       "yes" "$(stamp)"

check "still inside the grace period" "" "$(run "$blocked")"

printf '%s\n' "$(( $(date +%s) - 60 ))" >"$tmp/idle-since"
check "grace elapsed releases the hold" "release" "$(run "$blocked")"

# A watcher that died leaves its pid file behind, which must not read as a live assertion.
printf '%s\n' 99999999 >"$tmp/caffeinate.pid"; rm -f "$tmp/idle-since"
check "a dead hold pid is not a hold" "" "$(run "$blocked")"
check "a dead hold pid still asks for one" "hold" "$(run)"

: >"$tmp/empty.json"
check "empty agent output decides nothing" "" \
  "$(CAFFEINATE_AGENTS="$tmp/empty.json" ../watch.sh decide 2>/dev/null)"

exit $fail
