#!/usr/bin/env bash
# Usage: uncommitted-scope.sh <repo-dir>
# Branch `feat/restock` vs `origin/main`, reviewed with the `branch-uncommitted` scope.
#   src/Restock.kt:5    `0..items.size` reads past the end - committed
#   src/Inventory.kt:8  debug `println` - unstaged edit of a tracked file
#   src/Report.kt:3     division by zero on an empty list - untracked file
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Shop

Inventory helpers.
EOF

put src/Inventory.kt <<'EOF'
package shop

data class Item(val name: String, val qty: Int)

fun totalQty(items: List<Item>): Int = items.sumOf { it.qty }
EOF

commit "Initial inventory"
add_origin

git switch -q -c feat/restock
put src/Restock.kt <<'EOF'
package shop

fun restockOrder(items: List<Item>, target: Int): List<Pair<String, Int>> {
    val order = mutableListOf<Pair<String, Int>>()
    for (i in 0..items.size) {
        val missing = target - items[i].qty
        if (missing > 0) order += items[i].name to missing
    }
    return order
}
EOF
commit "Add restock order"

put src/Inventory.kt <<'EOF'
package shop

data class Item(val name: String, val qty: Int)

fun totalQty(items: List<Item>): Int = items.sumOf { it.qty }

fun lowStock(items: List<Item>, limit: Int): List<Item> {
    println("lowStock called with $items")
    return items.filter { it.qty < limit }
}
EOF

put src/Report.kt <<'EOF'
package shop

fun averageQty(items: List<Item>): Int = totalQty(items) / items.size
EOF
