#!/usr/bin/env bash
# Checks watch-state.sh with a real git repo.
set -u

here=$(cd "$(dirname "$0")" && pwd)
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# shellcheck source=watch-test-fakes.sh
source "$here/watch-test-fakes.sh"
# shellcheck source=watch-state.sh
source "$here/watch-state.sh"
wt=$(printf %s "$d/app" | shasum | cut -c1-12)

check "key: hub" app "$(watch_key "$d/app" 0)"
check "key: stack" "app-$wt" "$(watch_key "$d/app" 0 5 6)"
check "key: review" "app-$wt-review-5" "$(watch_key "$d/app" 1 5)"
check "state dir" "$d/state/watchd" "$WATCHD_DIR"

check "session pid: override" 4242 "$(WATCH_SESSION_PID=4242 watch_session_pid)"
# A fake ps that hides the claude process of the session that runs this test.
printf '#!/bin/sh\n/bin/ps "$@" | sed -E "s#(^|/)claude\$#\\1other#"\n' >"$d/bin/ps"
chmod +x "$d/bin/ps"
mkdir -p "$WATCHD_DIR"
check "session pid: no claude ancestor gives PPID" "$PPID" \
  "$(unset WATCH_SESSION_PID; watch_session_pid)"
check "session pid: no claude ancestor writes a log line" yes \
  "$(grep -q "no claude process above PID $PPID" "$WATCHD_DIR/watchd.log" 2>/dev/null && echo yes \
    || echo no)"
rm "$d/bin/ps"

sleep 30 &
sleeper=$!
check "alive: live process" yes "$(watch_alive "$sleeper" && echo yes || echo no)"
{ kill "$sleeper"; wait "$sleeper"; } 2>/dev/null
check "alive: dead process" no "$(watch_alive "$sleeper" && echo yes || echo no)"

watch_lock "$d/lock"
(sleep 1; watch_unlock "$d/lock") &
start=$(date +%s)
watch_lock "$d/lock"
check "lock: second lock waits, then gets it after unlock" "0 yes" \
  "$? $( (($(date +%s) - start >= 1)) && echo yes || echo no)"
watch_unlock "$d/lock"
check "lock: unlock removes the lock" no "$([ -e "$d/lock" ] && echo yes || echo no)"

mkdir "$d/lock"
touch -t "$(date -v-1M +%Y%m%d%H%M.%S)" "$d/lock"
start=$(date +%s)
watch_lock "$d/lock"
check "lock: stale lock broken" "0 yes" "$? $( (($(date +%s) - start < 3)) && echo yes || echo no)"
watch_unlock "$d/lock"

check "no herdr on PATH: watch_herdr_tokens returns 0" "0 no" \
  "$(PATH=/usr/bin:/bin watch_herdr_tokens wT watch_stage=watching; echo "$?") \
$([ -e "$d/herdr.log" ] && echo yes || echo no)"
touch "$d/herdr.fail"
watch_herdr_tokens wT watch_stage=watching
check "herdr error: watch_herdr_tokens returns 0 and writes a log line" "0 yes" \
  "$? $(grep -q 'herdr workspace wT: herdr: server_not_running' "$WATCHD_DIR/watchd.log" \
    && echo yes || echo no)"
rm -f "$d/herdr.fail"

mkdir "$d/scripts"
cp "$here"/watch-gitlab.sh "$here"/watch-lib.sh "$here"/watch-state.sh "$d/scripts/"
echo '# daemon' >"$d/scripts/watchd.sh"
before=$(WATCH_BIN="$d/scripts" watch_scripts_hash)
check "hash: same scripts, same hash" "$before" "$(WATCH_BIN="$d/scripts" watch_scripts_hash)"
echo '# changed' >>"$d/scripts/watchd.sh"
after=$(WATCH_BIN="$d/scripts" watch_scripts_hash)
check "hash changes when a script changes" yes "$([ "$before" != "$after" ] && echo yes || echo no)"
cp "$here"/repo-slug.sh "$d/scripts/"
before=$(WATCH_BIN="$d/scripts" watch_scripts_hash)
echo '# changed' >>"$d/scripts/repo-slug.sh"
after=$(WATCH_BIN="$d/scripts" watch_scripts_hash)
check "hash changes when repo-slug.sh changes" yes \
  "$([ "$before" != "$after" ] && echo yes || echo no)"

exit "$fail"
