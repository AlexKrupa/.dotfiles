#!/bin/sh
# Fixtures for bin/layout.jq. Run: bin/tests/test.sh
bin=$(dirname "$0")/..
fail=0

# check <name> <fixture> <filter> <expected...>
check() {
  name=$1 fixture=$2 filter=$3
  shift 3
  want=$(printf '%s\n' "$@" | sed '/^$/d')
  got=$(printf '%s' "$fixture" | jq -r -L "$bin" "include \"layout\"; $filter")
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    printf '  want: %s\n  got:  %s\n' "$(echo "$want" | tr '\n' '|')" "$(echo "$got" | tr '\n' '|')"
    fail=1
  fi
}

pane() { printf '{"type":"pane","pane_id":"%s"}' "$1"; }
split() { printf '{"type":"split","direction":"%s","ratio":%s,"first":%s,"second":%s}' "$1" "$2" "$3" "$4"; }
tree() { printf '{"result":{"layout":{"root":%s}}}' "$1"; }

# a | b | c, nested as (a | b) | c and skewed
columns=$(tree "$(split right 0.3 "$(split right 0.9 "$(pane a)" "$(pane b)")" "$(pane c)")")
# a | (b / c)
stack=$(tree "$(split right 0.3 "$(pane a)" "$(split down 0.8 "$(pane b)" "$(pane c)")")")
# ((a | b) / c) | d - two column groups, split apart by a row
nested=$(tree "$(split right 0.3 "$(split down 0.8 "$(split right 0.9 "$(pane a)" "$(pane b)")" "$(pane c)")" "$(pane d)")")
alone=$(tree "$(pane a)")
# a | b, already even
even=$(tree "$(split right 0.5 "$(pane a)" "$(pane b)")")
# a | (b | c) with the outer split off and the inner one already even
partly=$(tree "$(split right 0.3 "$(pane a)" "$(split right 0.5 "$(pane b)" "$(pane c)")")")
# the same tree with the outer split at the f32 the server hands back for 1/3
f32=$(tree "$(split right 0.33333331 "$(pane a)" "$(split right 0.5 "$(pane b)" "$(pane c)")")")

check "columns even as one group" "$columns" 'equalize("a"; "right")' \
  "[] 0.6666666666666666" "[false] 0.5"
check "a column group is not a row group" "$columns" 'equalize("a"; "down")'
check "the stack alone" "$stack" 'equalize("b"; "down")' "[true] 0.5"
check "no row group above that pane" "$stack" 'equalize("a"; "down")'
check "no direction takes the whole tab" "$stack" 'equalize("a"; "")' \
  "[] 0.5" "[true] 0.5"
check "the run the pane is in, not the one above" "$nested" 'equalize("a"; "right")' \
  "[false,false] 0.5"
check "the row between the two runs" "$nested" 'equalize("a"; "down")' "[false] 0.5"
check "a pane of another tab" "$columns" 'equalize("zz"; "right")'
check "one pane is no group" "$alone" 'equalize("a"; "right")'
check "an even group writes nothing" "$even" 'equalize("a"; "right")'
check "only the split that is off" "$partly" 'equalize("a"; "right")' \
  "[] 0.3333333333333333"
check "f32 noise counts as even" "$f32" 'equalize("a"; "right")'

check "close takes the collapsing split" "$columns" 'close_target("b")' "right a"
check "close reaches into the other side" "$columns" 'close_target("c")' "right a"
check "close inside a stack" "$stack" 'close_target("c")' "down b"
check "closing the whole tab" "$alone" 'close_target("a")'

exit $fail
