#!/usr/bin/env bash
# Checks watch-lib.sh with fake pmset, nc, sleep, and date.
set -u

here=$(cd "$(dirname "$0")" && pwd)
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# `next NAME` prints the next line of $D/NAME.txt, and the last line again after the end.
# $D/NAME.n counts the calls. pmset and date print the next line, nc exits with it. sleep adds
# its argument to $D/sleep.log.
mkdir -p "$d/bin"
cat >"$d/bin/next" <<'EOF'
#!/bin/sh
n=$(($(cat "$D/$1.n" 2>/dev/null || echo 0) + 1))
echo "$n" >"$D/$1.n"
lines=$(wc -l <"$D/$1.txt")
[ "$n" -le "$lines" ] || n=$lines
sed -n "${n}p" "$D/$1.txt"
EOF
printf '#!/bin/sh\nexec next pmset\n' >"$d/bin/pmset"
printf '#!/bin/sh\nexit "$(next nc)"\n' >"$d/bin/nc"
printf '#!/bin/sh\nexec next date\n' >"$d/bin/date"
printf '#!/bin/sh\necho "$1" >>"$D/sleep.log"\n' >"$d/bin/sleep"
chmod +x "$d/bin/"*
export PATH="$d/bin:$PATH" D="$d"

# shellcheck source=watch-lib.sh
source "$here/watch-lib.sh"
sleeper=''
WATCH_HOST=gitlab.example.com
wake='Current System Capabilities are: CPU Graphics Audio Network'
dark='Current System Capabilities are: CPU Network'

reset() { rm -f "$d"/*.n "$d"/*.txt "$d/sleep.log"; }
lines() { local f=$1; shift; printf '%s\n' "$@" >"$d/$f.txt"; }
count() { cat "$d/$1.n" 2>/dev/null || echo 0; }
slept() { paste -s -d ' ' "$d/sleep.log" 2>/dev/null; }

is_network_error 'dial tcp: lookup gitlab.example.com: no such host'
check "network error: no such host" 0 $?
is_network_error "fatal: unable to access 'https://gitlab.example.com/app.git/': Could not resolve host: gitlab.example.com"
check "network error: git fetch" 0 $?
is_network_error 'HTTP 404 Not Found'
check "not a network error: HTTP 404" 1 $?
is_network_error 'HTTP 403 Forbidden'
check "not a network error: HTTP 403" 1 $?

check "remote_host: https" gitlab.example.com "$(remote_host https://gitlab.example.com/group/app.git)"
check "remote_host: git@" gitlab.example.com "$(remote_host git@gitlab.example.com:group/app.git)"
check "remote_host: local path" "" "$(remote_host /tmp/origin.git)"

reset; lines pmset "$wake"; lines nc 1
online gitlab.example.com
check "online: no network" 1 $?

reset; lines pmset "$dark" "$wake"; lines nc 1 0
wait_online gitlab.example.com
check "wait_online: returns" 0 $?
check "wait_online: probes only during full wake" 2 "$(count nc)"
check "wait_online: waits between probes" "10 10" "$(slept)"

reset; lines pmset "$wake"; lines nc 1
wait_online ''
check "wait_online with no host: returns" 0 $?
check "wait_online with no host: no probe" 0 "$(count nc)"

reset; lines pmset "$wake"; lines nc 0; lines date 1000 1010 1010 1020 1020 1025
nap 25
check "nap: steps" "10 10 5" "$(slept)"

reset; lines pmset "$wake"; lines nc 0; lines date 1000 4600
nap 25
check "nap after a sleep: returns after the first step" 10 "$(slept)"
check "nap after a sleep: waits for the network" "1 1" "$(count pmset) $(count nc)"

reset; lines pmset "$dark" "$dark" "$wake"; lines nc 0; lines date 1000 1010
nap 25
check "nap with no full wake: waits for full wake, then returns" "10 10" "$(slept)"

exit "$fail"
