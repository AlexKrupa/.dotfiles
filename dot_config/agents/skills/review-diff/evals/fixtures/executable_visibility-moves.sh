#!/usr/bin/env bash
# Usage: visibility-moves.sh <repo-dir>
# Branch `feat/payment-mapper` vs `main` (with origin). Gradle, no docs. No dependency changes.
# Boundary changes (expect Visibility and Moves groups, no Dependencies group):
#   PaymentApi.charge  (:core:payments)  internal -> public   wider
#   Ledger.round       (:core:payments)  private -> internal  wider, for a new test
#   CartStore          (:feature:cart)   public -> internal   narrower
#   PaymentMapper.kt   :feature:checkout -> :core:payments    wider (2 dependents vs 1)
# Not in the section: new public class Receipt, the test helper CartStoreTest.fixture that becomes
# public, and Format.kt, which moves inside :feature:cart.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
rootProject.name = "shop"
include(":app", ":feature:cart", ":feature:checkout", ":core:payments")
EOF

# module <path> <deps...> - writes <path>/build.gradle.kts with project dependencies.
module() {
  local path="$1"; shift
  local dir="${path#:}"; dir="${dir//://}"
  {
    printf 'plugins {\n    kotlin("jvm")\n}\n\ndependencies {\n'
    for d in "$@"; do printf '    implementation(project("%s"))\n' "$d"; done
    printf '}\n'
  } | put "$dir/build.gradle.kts"
}

module :app :feature:cart :feature:checkout
module :feature:cart :core:payments
module :feature:checkout :core:payments
module :core:payments

put core/payments/src/main/kotlin/shop/payments/PaymentApi.kt <<'EOF'
package shop.payments

class PaymentApi(private val ledger: Ledger) {
    internal fun charge(cents: Long): Boolean {
        if (cents <= 0) return false
        ledger.record(cents)
        return true
    }
}
EOF

put core/payments/src/main/kotlin/shop/payments/Ledger.kt <<'EOF'
package shop.payments

class Ledger {
    private val entries = mutableListOf<Long>()

    fun record(cents: Long) {
        entries += round(cents)
    }

    private fun round(cents: Long): Long = cents - cents % 5
}
EOF

put feature/cart/src/main/kotlin/shop/cart/CartStore.kt <<'EOF'
package shop.cart

class CartStore {
    private val items = mutableMapOf<String, Long>()

    fun add(sku: String, priceCents: Long) {
        items[sku] = priceCents
    }

    fun totalCents(): Long = items.values.sum()
}
EOF

put feature/cart/src/main/kotlin/shop/cart/util/Format.kt <<'EOF'
package shop.cart.util

fun formatCents(cents: Long): String {
    val whole = cents / 100
    val fraction = cents % 100
    return "$whole.${fraction.toString().padStart(2, '0')}"
}
EOF

put feature/cart/src/test/kotlin/shop/cart/CartStoreTest.kt <<'EOF'
package shop.cart

import kotlin.test.Test
import kotlin.test.assertEquals

class CartStoreTest {
    @Test
    fun `total sums all items`() {
        assertEquals(300, fixture().totalCents())
    }

    private fun fixture() = CartStore().apply {
        add("a", 100)
        add("b", 200)
    }
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/PaymentMapper.kt <<'EOF'
package shop.checkout

object PaymentMapper {
    fun toCents(amount: Double): Long = Math.round(amount * 100)

    fun toAmount(cents: Long): Double = cents / 100.0

    fun isRefund(cents: Long): Boolean = cents < 0

    fun describe(cents: Long): String = if (isRefund(cents)) "refund $cents" else "charge $cents"
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutService.kt <<'EOF'
package shop.checkout

import shop.payments.PaymentApi

class CheckoutService(private val api: PaymentApi) {
    fun pay(amount: Double): Boolean = api.charge(PaymentMapper.toCents(amount))
}
EOF

commit "Initial shop modules"
add_origin

git switch -q -c feat/payment-mapper

sed -i '' 's/    internal fun charge/    fun charge/' core/payments/src/main/kotlin/shop/payments/PaymentApi.kt
sed -i '' 's/    private fun round/    internal fun round/' core/payments/src/main/kotlin/shop/payments/Ledger.kt
sed -i '' 's/^class CartStore {/internal class CartStore {/' feature/cart/src/main/kotlin/shop/cart/CartStore.kt
sed -i '' 's/    private fun fixture()/    fun fixture()/' feature/cart/src/test/kotlin/shop/cart/CartStoreTest.kt

mkdir -p core/payments/src/main/kotlin/shop/payments
git mv feature/checkout/src/main/kotlin/shop/checkout/PaymentMapper.kt \
  core/payments/src/main/kotlin/shop/payments/PaymentMapper.kt
sed -i '' 's/^package shop.checkout$/package shop.payments/' \
  core/payments/src/main/kotlin/shop/payments/PaymentMapper.kt
sed -i '' 's/^import shop.payments.PaymentApi$/import shop.payments.PaymentApi\nimport shop.payments.PaymentMapper/' \
  feature/checkout/src/main/kotlin/shop/checkout/CheckoutService.kt

git mv feature/cart/src/main/kotlin/shop/cart/util/Format.kt feature/cart/src/main/kotlin/shop/cart/Format.kt
sed -i '' 's/^package shop.cart.util$/package shop.cart/' feature/cart/src/main/kotlin/shop/cart/Format.kt

put core/payments/src/main/kotlin/shop/payments/Receipt.kt <<'EOF'
package shop.payments

class Receipt(val cents: Long) {
    fun text(): String = "Paid ${PaymentMapper.toAmount(cents)}"
}
EOF

put core/payments/src/test/kotlin/shop/payments/LedgerTest.kt <<'EOF'
package shop.payments

import kotlin.test.Test
import kotlin.test.assertEquals

class LedgerTest {
    @Test
    fun `round drops the remainder of 5`() {
        assertEquals(105, Ledger().round(107))
    }
}
EOF

commit "Move PaymentMapper to payments and adjust visibility"
