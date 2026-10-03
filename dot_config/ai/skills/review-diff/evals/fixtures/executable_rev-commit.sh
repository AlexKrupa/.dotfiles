#!/usr/bin/env bash
# Usage: rev-commit.sh <repo-dir>
# Branch `feat/search` with three commits. The prompt reviews only the middle commit (`rev`).
#   src/Search.kt:5     `high = sorted.size` with `low <= high` reads past the end - in scope
#   src/MathUtil.kt:3   `clamp` returns `lo` when `x > hi` - first commit, out of scope
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Util

Small helpers.
EOF

commit "Initial readme"
add_origin

git switch -q -c feat/search
put src/MathUtil.kt <<'EOF'
package util

fun clamp(x: Int, lo: Int, hi: Int): Int = if (x < lo) lo else if (x > hi) lo else x
EOF
commit "Add clamp"

put src/Search.kt <<'EOF'
package util

fun indexOf(sorted: List<Int>, target: Int): Int {
    var low = 0
    var high = sorted.size
    while (low <= high) {
        val mid = (low + high) / 2
        when {
            sorted[mid] == target -> return mid
            sorted[mid] < target -> low = mid + 1
            else -> high = mid - 1
        }
    }
    return -1
}
EOF
commit "Add binary search"
rev="$(git rev-parse --short HEAD)"

put README.md <<'EOF'
# Util

Small helpers: `clamp` and `indexOf`.
EOF
commit "Document helpers"

printf 'rev=%s\n' "$rev"
