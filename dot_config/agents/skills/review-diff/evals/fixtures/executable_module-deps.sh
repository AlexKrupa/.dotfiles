#!/usr/bin/env bash
# Usage: module-deps.sh <repo-dir>
# Branch `feat/payments-module` vs `main` (with origin). Gradle, no docs.
# Structure change (expect a module diagram):
#   new module :core:payments, depends on :core:network
#   :feature:checkout  -> :core:payments  new edge
#   :feature:checkout  -> :core:legacy    removed edge
# Unchanged and not relevant: :feature:search, :feature:profile, :core:ui.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
rootProject.name = "shop"
include(":app")
include(":feature:cart", ":feature:checkout", ":feature:search", ":feature:profile")
include(":core:network", ":core:legacy", ":core:ui")
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

module :app :feature:cart :feature:checkout :feature:search :feature:profile
module :feature:cart :core:ui
module :feature:checkout :core:network :core:legacy :core:ui
module :feature:search :core:network :core:ui
module :feature:profile :core:network :core:ui
module :core:network
module :core:legacy :core:network
module :core:ui

put core/network/src/main/kotlin/shop/network/HttpClient.kt <<'EOF'
package shop.network

class HttpClient(private val baseUrl: String) {
    fun post(path: String, body: String): String = "$baseUrl$path <- $body"
}
EOF

put core/legacy/src/main/kotlin/shop/legacy/LegacyPaymentClient.kt <<'EOF'
package shop.legacy

import shop.network.HttpClient

class LegacyPaymentClient(private val http: HttpClient) {
    fun charge(cents: Long): Boolean = http.post("/v1/charge", "$cents").isNotEmpty()
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutService.kt <<'EOF'
package shop.checkout

import shop.legacy.LegacyPaymentClient

class CheckoutService(private val payments: LegacyPaymentClient) {
    fun pay(totalCents: Long): Boolean = payments.charge(totalCents)
}
EOF

put feature/search/src/main/kotlin/shop/search/SearchService.kt <<'EOF'
package shop.search

import shop.network.HttpClient

class SearchService(private val http: HttpClient) {
    fun search(query: String): String = http.post("/search", query)
}
EOF

commit "Initial shop modules"
add_origin

git switch -q -c feat/payments-module

sed -i '' 's/include(":core:network", ":core:legacy", ":core:ui")/include(":core:network", ":core:legacy", ":core:payments", ":core:ui")/' settings.gradle.kts
module :core:payments :core:network
module :feature:checkout :core:network :core:payments :core:ui

put core/payments/src/main/kotlin/shop/payments/PaymentClient.kt <<'EOF'
package shop.payments

import shop.network.HttpClient

class PaymentClient(private val http: HttpClient) {
    fun charge(cents: Long, idempotencyKey: String): Boolean =
        http.post("/v2/payments", "$cents;$idempotencyKey").isNotEmpty()
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutService.kt <<'EOF'
package shop.checkout

import java.util.UUID
import shop.payments.PaymentClient

class CheckoutService(private val payments: PaymentClient) {
    fun pay(totalCents: Long): Boolean = payments.charge(totalCents, UUID.randomUUID().toString())
}
EOF

commit "Move checkout to the new payments module"
