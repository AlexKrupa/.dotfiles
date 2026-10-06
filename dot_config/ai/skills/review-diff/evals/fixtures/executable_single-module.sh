#!/usr/bin/env bash
# Usage: single-module.sh <repo-dir>
# Branch `fix/cart-total` vs `main` (with origin). Gradle, several modules.
# The branch changes one function body in :feature:cart. No build file changes, no new class.
# Expect no diagram.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
rootProject.name = "shop"
include(":app", ":feature:cart", ":feature:checkout", ":core:ui")
EOF

put feature/cart/build.gradle.kts <<'EOF'
plugins {
    kotlin("jvm")
}

dependencies {
    implementation(project(":core:ui"))
}
EOF

put feature/checkout/build.gradle.kts <<'EOF'
plugins {
    kotlin("jvm")
}

dependencies {
    implementation(project(":core:ui"))
}
EOF

put feature/cart/src/main/kotlin/shop/cart/CartTotals.kt <<'EOF'
package shop.cart

data class Line(val priceCents: Long, val quantity: Int)

class CartTotals {
    fun total(lines: List<Line>): Long = lines.sumOf { it.priceCents }
}
EOF

commit "Initial shop modules"
add_origin

git switch -q -c fix/cart-total

put feature/cart/src/main/kotlin/shop/cart/CartTotals.kt <<'EOF'
package shop.cart

data class Line(val priceCents: Long, val quantity: Int)

class CartTotals {
    fun total(lines: List<Line>): Long = lines.sumOf { it.priceCents * it.quantity }
}
EOF

commit "Multiply line price by quantity in the cart total"
