#!/usr/bin/env bash
set -u

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake backends print their name, the argument count, and the arguments.
mkdir -p "$tmp/mux"
cp "$here/mux.sh" "$tmp/mux.sh" 2>/dev/null
for backend in herdr rex; do
  printf '#!/bin/sh\necho "%s $# $*"\n' "$backend" >"$tmp/mux/$backend.sh"
  chmod +x "$tmp/mux/$backend.sh"
done
mux() { env -u HERDR_ENV -u REX_SESSION "$@"; }

out=$(mux HERDR_ENV=1 "$tmp/mux.sh" pane-current 2>&1)
check "routes to herdr when HERDR_ENV is 1" "herdr 1 pane-current" "$out"

out=$(mux REX_SESSION=s1 "$tmp/mux.sh" pane-current 2>&1)
check "routes to rex when REX_SESSION is set" "rex 1 pane-current" "$out"

out=$(mux HERDR_ENV=1 REX_SESSION=s1 "$tmp/mux.sh" pane-current 2>&1)
check "prefers herdr when both are set" "herdr 1 pane-current" "$out"

err=$(mux "$tmp/mux.sh" pane-current 2>&1 >/dev/null); code=$?
check "exits 4 outside a multiplexer: exit 4" 4 "$code"
check "exits 4 outside a multiplexer: error" "mux: not in herdr or Rex" "$err"

out=$(mux HERDR_ENV=1 "$tmp/mux.sh" agent-prompt p1 "a b" 2>&1)
check "passes arguments with spaces unchanged" "herdr 3 agent-prompt p1 a b" "$out"

exit $fail
