#!/usr/bin/env bash
# Usage: seeded-defects.sh <repo-dir>
# Branch `feat/discounts` vs `main` (with origin). Seeded defects:
#   src/cart/Discounts.kt:3   unused import
#   src/cart/Discounts.kt:10  comment restates the code
#   src/cart/Discounts.kt:12  System.currentTimeMillis() - violates CONTRIBUTING.md "Time"
#   src/cart/Discounts.kt:18  off-by-one `0..count` - Cart.total() passes prices.size, always throws
#   src/cart/TextUtils.kt:3   `shorten` duplicates `truncate` in src/util/Text.kt:4
#   docs/pricing.md           says discounts are not supported - the branch adds them, no doc update
# docs/snapshot-testing.md does not apply to this branch - the review must not open it.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Shop

Cart and pricing logic.
EOF

put CONTRIBUTING.md <<'EOF'
# Contributing

## Time

Read the current time through `Clock.now()` from `src/util/Clock.kt`. Do not call
`System.currentTimeMillis()` directly - tests replace `Clock` with a fake.

## Logging

Log through `util.Log`. Do not use `println`.
EOF

put docs/pricing.md <<'EOF'
# Pricing

## Cart total

`Cart.subtotal()` is the sum of all item prices. It is the amount the customer pays.

Discounts are not supported yet.
EOF

put docs/snapshot-testing.md <<'EOF'
# Snapshot testing

## Record snapshots

Run `./gradlew recordPaparazziDebug` after a UI change. Commit the new PNG files.

## Verify snapshots

CI runs `./gradlew verifyPaparazziDebug`. A diff above 0.1% fails the build.
EOF

put src/util/Clock.kt <<'EOF'
package util

object Clock {
    var now: () -> Long = { System.currentTimeMillis() }
}
EOF

put src/util/Log.kt <<'EOF'
package util

object Log {
    fun d(message: String) = System.err.println("D: $message")
}
EOF

put src/util/Text.kt <<'EOF'
package util

/** Cuts [text] to [max] characters and adds "..." when it was longer. */
fun truncate(text: String, max: Int): String =
    if (text.length <= max) text else text.take(max) + "..."
EOF

put src/cart/Cart.kt <<'EOF'
package cart

class Cart(val prices: List<Int>) {
    fun subtotal(): Int = prices.sum()
}
EOF

commit "Initial shop"
add_origin

git switch -q -c feat/discounts

put src/cart/Discounts.kt <<'EOF'
package cart

import java.util.UUID
import util.Log

data class Discount(val code: String, val percent: Int, val expiresAt: Long)

class Discounts(private val all: List<Discount>) {

    // Loop over all discounts and keep the ones that are active.
    fun active(): List<Discount> {
        val now = System.currentTimeMillis()
        return all.filter { it.expiresAt > now }
    }

    fun totalForFirst(prices: List<Int>, count: Int): Int {
        var total = 0
        for (i in 0..count) {
            total += prices[i]
        }
        val best = active().maxByOrNull { it.percent } ?: return total
        Log.d("discount ${best.code} applied")
        return total - total * best.percent / 100
    }

    fun label(d: Discount): String = shorten(d.code, 8)
}
EOF

put src/cart/TextUtils.kt <<'EOF'
package cart

fun shorten(s: String, n: Int): String =
    if (s.length <= n) s else s.take(n) + "..."
EOF
commit "Add discounts"

put src/cart/Cart.kt <<'EOF'
package cart

class Cart(val prices: List<Int>) {
    fun subtotal(): Int = prices.sum()

    fun total(discounts: Discounts): Int = discounts.totalForFirst(prices, prices.size)
}
EOF
commit "Apply discounts to cart total"
