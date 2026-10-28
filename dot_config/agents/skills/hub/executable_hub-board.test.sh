#!/usr/bin/env bash
# Checks hub-board.sh with a fake herdr.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/hub-board.sh"
d=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$d"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Fake herdr: `pane list` prints $MOCK_PANES. MOCK_FAIL=split makes the split fail.
mkdir -p "$d/bin"
cat >"$d/bin/herdr" <<'EOF'
#!/bin/sh
printf 'herdr %s\n' "$*" >>"$MOCK_LOG"
case "$1 $2" in
  "pane current") echo '{"result":{"pane":{"pane_id":"w1:p1","workspace_id":"w1"}}}' ;;
  "pane list") cat "$MOCK_PANES" ;;
  "pane split")
    [ "${MOCK_FAIL:-}" != split ] || { echo "no room for a split" >&2; exit 1; }
    echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "pane run" | "pane rename") ;;
  *) echo "unexpected herdr call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$d/bin/herdr"
export PATH="$d/bin:$PATH" MOCK_LOG="$d/calls.log" MOCK_PANES="$d/panes.json"
repo="$d/my repo"
mkdir -p "$repo"

echo '{"result":{"panes":[{"pane_id":"w1:p1","label":null}]}}' >"$MOCK_PANES"
"$script" --repo "$repo"; code=$?
check "no board pane: exit 0" 0 "$code"
check "no board pane: split, run, label" "$(printf '%s\n' \
  'herdr pane current --current' \
  'herdr pane list --workspace w1' \
  "herdr pane split w1:p1 --direction right --cwd $repo" \
  "herdr pane run w1:p9 watchd board --repo $(printf '%q' "$repo")" \
  'herdr pane rename w1:p9 watchd board')" "$(cat "$MOCK_LOG")"

: >"$MOCK_LOG"
echo '{"result":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2","label":"watchd board"}]}}' >"$MOCK_PANES"
"$script" --repo "$repo"; code=$?
check "board pane exists: exit 0" 0 "$code"
check "board pane exists: no split" "" "$(grep -E 'split|run|rename' "$MOCK_LOG")"

echo '{"result":{"panes":[]}}' >"$MOCK_PANES"
out=$(MOCK_FAIL=split "$script" --repo "$repo" 2>&1); code=$?
check "split fails: exit 1" 1 "$code"
check "split fails: herdr text" "hub-board: no room for a split" "$out"

exit "$fail"
