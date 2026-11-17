#!/bin/sh
dir=$(dirname "$0")
fail=0

# check <name> <fixture> <expected>
check() {
  got=$(printf '%s' "$2" | jq -c -L "$dir" 'include "tab-split"; tab_split_plan')
  want=$(printf '%s' "$3" | jq -c .)
  if [ "$got" = "$want" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    printf '  want: %s\n  got:  %s\n' "$want" "$got"
    fail=1
  fi
}

pane() { printf '{"type":"pane","pane_id":"%s"}' "$1"; }
split() { printf '{"type":"split","direction":"%s","ratio":%s,"first":%s,"second":%s}' "$1" "$2" "$3" "$4"; }
tree() { printf '{"result":{"layout":{"root":%s}}}' "$1"; }
move() { printf '{"pane":"%s","target":"%s","direction":"%s","ratio":%s}' "$1" "$2" "$3" "$4"; }

check "alone" "$(tree "$(pane a)")" \
  '{"anchor":"a","parked":[],"ratio":0.5,"moves":[]}'

check "stack" "$(tree "$(split down 0.7 "$(pane a)" "$(pane b)")")" \
  "{\"anchor\":\"a\",\"parked\":[\"b\"],\"ratio\":0.5,
    \"moves\":[$(move b a down 0.7)]}"

check "columns" "$(tree "$(split right 0.4 "$(pane a)" "$(pane b)")")" \
  "{\"anchor\":\"a\",\"parked\":[\"b\"],\"ratio\":0.6666666666666666,
    \"moves\":[$(move b a right 0.4)]}"

# a | (b / c)
check "mixed" "$(tree "$(split right 0.3 "$(pane a)" "$(split down 0.6 "$(pane b)" "$(pane c)")")")" \
  "{\"anchor\":\"a\",\"parked\":[\"b\",\"c\"],\"ratio\":0.6666666666666666,
    \"moves\":[$(move b a right 0.3),$(move c b down 0.6)]}"

# ((a | b) / c) | d
check "nested" \
  "$(tree "$(split right 0.3 "$(split down 0.8 "$(split right 0.9 "$(pane a)" "$(pane b)")" "$(pane c)")" "$(pane d)")")" \
  "{\"anchor\":\"a\",\"parked\":[\"b\",\"c\",\"d\"],\"ratio\":0.6666666666666666,
    \"moves\":[$(move d a right 0.3),$(move c a down 0.8),$(move b a right 0.9)]}"

exit $fail
