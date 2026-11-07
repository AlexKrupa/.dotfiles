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

# Fake backends print their name, the argument count, the arguments, and MUX_PANE. repo-pane
# prints $MOCK_<BACKEND>_PANE, and exits 1 when it is empty.
mkdir -p "$tmp/mux"
cp "$here/mux.sh" "$tmp/mux.sh" 2>/dev/null
for backend in herdr rex; do
  upper=$(printf '%s' "$backend" | tr a-z A-Z)
  cat >"$tmp/mux/$backend.sh" <<EOF
#!/bin/sh
if [ "\$1" = repo-pane ]; then
  [ -n "\${MOCK_${upper}_PANE:-}" ] || exit 1
  echo "\$MOCK_${upper}_PANE"; exit 0
fi
echo "$backend \$# \$*\${MUX_PANE:+ (pane \$MUX_PANE)}"
EOF
  chmod +x "$tmp/mux/$backend.sh"
done
mux() { env -u HERDR_ENV -u REX_SESSION -u MUX_REPO -u MUX_PANE "$@"; }

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

out=$(mux MUX_REPO=/repo MOCK_REX_PANE=b1 "$tmp/mux.sh" pane-current 2>&1)
check "with no pane, routes to the multiplexer with a pane in MUX_REPO" "rex 1 pane-current (pane b1)" \
  "$out"

out=$(mux MUX_REPO=/repo MOCK_HERDR_PANE=w1:p1 MOCK_REX_PANE=b1 "$tmp/mux.sh" pane-current 2>&1)
check "with no pane, prefers herdr when both have a pane in MUX_REPO" \
  "herdr 1 pane-current (pane w1:p1)" "$out"

err=$(mux MUX_REPO=/repo "$tmp/mux.sh" pane-current 2>&1 >/dev/null); code=$?
check "with no pane and no multiplexer pane in MUX_REPO: exit 4 and error" \
  "4 mux: no herdr or Rex pane in /repo" "$code $err"

out=$(mux REX_SESSION=s1 MUX_REPO=/repo MOCK_HERDR_PANE=w1:p1 "$tmp/mux.sh" pane-current 2>&1)
check "a pane wins over MUX_REPO" "rex 1 pane-current" "$out"

exit $fail
