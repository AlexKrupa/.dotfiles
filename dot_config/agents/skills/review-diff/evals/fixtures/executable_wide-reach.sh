#!/usr/bin/env bash
# Usage: wide-reach.sh <repo-dir>
# Branch `feat/compact-prices` vs `main` (with origin). The repo has no docs.
# High-impact changes:
#   core/util/Prices.kt      formatPrice output changes on purpose - 12 call sites in 6 modules
# Changes that must not be high-impact:
#   cart/di/CartModule.kt    new DI module that provides one cart-local dependency
#   core/util/Strings.kt     new shared ellipsize() with one caller - a Simplicity finding instead
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
include(":core", ":cart", ":checkout", ":orders", ":search", ":wishlist", ":deals")
EOF

put core/util/Prices.kt <<'EOF'
package core.util

fun formatPrice(cents: Long): String = "%d.%02d".format(cents / 100, cents % 100)
EOF

# caller <module> <class> - writes <module>/<Class>.kt with one formatPrice call site.
caller() {
  put "$1/$2.kt" <<EOF
package $1

import core.util.formatPrice

class $2 {
    fun label(cents: Long): String = "Price: \${formatPrice(cents)}"
}
EOF
}

caller cart CartRow
caller cart CartTotal
caller checkout Summary
caller checkout Receipt
caller checkout PaymentSheet
caller orders OrderRow
caller orders OrderDetail
caller orders Invoice
caller search ResultRow
caller search Filters
caller wishlist WishRow
caller deals DealBanner

put cart/CartRepository.kt <<'EOF'
package cart

interface CartRepository {
    fun items(): List<String>
}

class InMemoryCartRepository : CartRepository {
    override fun items(): List<String> = emptyList()
}
EOF

commit "Initial shop modules"
add_origin

git switch -q -c feat/compact-prices

put core/util/Prices.kt <<'EOF'
package core.util

fun formatPrice(cents: Long): String =
    if (cents % 100 == 0L) "${cents / 100}" else "%d.%02d".format(cents / 100, cents % 100)
EOF

put core/util/Strings.kt <<'EOF'
package core.util

fun String.ellipsize(max: Int): String = if (length <= max) this else take(max - 1) + "…"
EOF

put cart/di/CartModule.kt <<'EOF'
package cart.di

import cart.CartRepository
import cart.InMemoryCartRepository

object CartModule {
    fun cartRepository(): CartRepository = InMemoryCartRepository()
}
EOF

put cart/CartRow.kt <<'EOF'
package cart

import core.util.ellipsize
import core.util.formatPrice

class CartRow {
    fun label(cents: Long): String = "Price: ${formatPrice(cents)}"

    fun title(name: String): String = name.ellipsize(24)
}
EOF

commit "Drop trailing zeros from whole prices, per the new design"
