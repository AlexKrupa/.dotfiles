#!/usr/bin/env bash
# Usage: stacked-branch.sh <repo-dir>
# Stack: main (with origin) <- feat/median <- feat/mode (checked out).
# The expected parent is `feat/median` (ancestor-branch).
#   src/math/Median.kt:5  wrong median for even sizes - introduced on feat/median, so out of scope
#   src/math/Mode.kt:4    `maxBy` throws on an empty list - in scope
# feat/mode calls `median()`, so Median.kt is a direct callee (adjacent radius, Simplicity only).
source "$(dirname "$0")/lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Stats

Small statistics helpers.
EOF

put src/math/Stats.kt <<'EOF'
package math

fun mean(xs: List<Double>): Double = xs.sum() / xs.size
EOF

commit "Initial stats"
add_origin

git switch -q -c feat/median
put src/math/Median.kt <<'EOF'
package math

fun median(xs: List<Double>): Double {
    val sorted = xs.sorted()
    return sorted[sorted.size / 2]
}
EOF
commit "Add median"

git switch -q -c feat/mode
put src/math/Mode.kt <<'EOF'
package math

fun mode(xs: List<Int>): Int =
    xs.groupingBy { it }.eachCount().maxBy { it.value }.key
EOF

put src/math/Stats.kt <<'EOF'
package math

fun mean(xs: List<Double>): Double = xs.sum() / xs.size

fun summary(xs: List<Int>): String {
    val ds = xs.map { it.toDouble() }
    return "mean=${mean(ds)} median=${median(ds)} mode=${mode(xs)}"
}
EOF
commit "Add mode and summary"
