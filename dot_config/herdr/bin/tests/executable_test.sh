#!/bin/sh
bin=$(dirname "$0")/..
fail=0

# check <name> <fixture> <filter> <expected...>
check() {
  name=$1 fixture=$2 filter=$3
  shift 3
  want=$(printf '%s\n' "$@" | sed '/^$/d')
  got=$(printf '%s' "$fixture" | jq -r -L "$bin" "include \"balance\"; $filter")
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
check "no row group under that pane" "$nested" 'equalize("a"; "down")'
check "a pane of another tab" "$columns" 'equalize("zz"; "right")'
check "one pane is no group" "$alone" 'equalize("a"; "right")'
check "an even group writes nothing" "$even" 'equalize("a"; "right")'
check "only the split that is off" "$partly" 'equalize("a"; "right")' \
  "[] 0.3333333333333333"
check "f32 noise counts as even" "$f32" 'equalize("a"; "right")'

check "close takes the collapsing split" "$columns" 'close_target("b")' "right [false]"
check "close at the root" "$columns" 'close_target("c")' "right []"
check "close inside a stack" "$stack" 'close_target("c")' "down [true]"
check "closing the whole tab" "$alone" 'close_target("a")'

# The trees the closes above leave behind, which is what equalize_at reads.
# a | c, from closing b out of the three columns
closed_columns=$(tree "$(split right 0.3 "$(pane a)" "$(pane c)")")
# a | (c / d), from closing b out of a | b | (c / d): the group loses a column
closed_hoist=$(tree "$(split right 0.3 "$(pane a)" "$(split down 0.5 "$(pane c)" "$(pane d)")")")
# a | ((c | d) / e), from closing b out of a | ((b | c | d) / e)
closed_inner=$(tree "$(split right 0.7 "$(pane a)" \
  "$(split down 0.5 "$(split right 0.9 "$(pane c)" "$(pane d)")" "$(pane e)")")")

check "the group the closed pane left" "$closed_columns" 'equalize_at([]; "right")' "[] 0.5"
check "the group reaches past the hoisted stack" "$closed_hoist" 'equalize_at([]; "right")' \
  "[] 0.5"
check "a column group inside a row leaves the tab alone" "$closed_inner" \
  'equalize_at([true,false]; "right")' "[true,false] 0.5"
check "nothing left of that column group" \
  "$(tree "$(split right 0.7 "$(pane a)" "$(split down 0.5 "$(pane c)" "$(pane e)")")")" \
  'equalize_at([true,false]; "right")'

exit $fail
