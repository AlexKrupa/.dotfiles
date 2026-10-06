#!/usr/bin/env bash
# Usage: class-flow.sh <repo-dir>
# Branch `feat/async-payment` vs `main` (with origin). Gradle. All changes are in
# :feature:checkout. No build file changes - expect no module diagram.
# The branch replaces a direct call with an event round trip that the code does not make obvious
# (expect a class diagram):
#   CheckoutViewModel --PaymentRequested--> CheckoutEvents (SharedFlow)
#   PaymentProcessor collects CheckoutEvents, calls PaymentGateway, writes PaymentStatusStore
#   CheckoutViewModel observes PaymentStatusStore.status (StateFlow)
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
rootProject.name = "shop"
include(":app", ":feature:checkout", ":core:network")
EOF

put feature/checkout/build.gradle.kts <<'EOF'
plugins {
    kotlin("jvm")
}

dependencies {
    implementation(project(":core:network"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/PaymentGateway.kt <<'EOF'
package shop.checkout

interface PaymentGateway {
    suspend fun charge(orderId: String, cents: Long): Boolean
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutViewModel.kt <<'EOF'
package shop.checkout

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

class CheckoutViewModel(
    private val gateway: PaymentGateway,
    private val scope: CoroutineScope,
) {
    private val _paid = MutableStateFlow(false)
    val paid: StateFlow<Boolean> = _paid

    fun onPayClicked(orderId: String, cents: Long) {
        scope.launch { _paid.value = gateway.charge(orderId, cents) }
    }
}
EOF

commit "Initial checkout"
add_origin

git switch -q -c feat/async-payment

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutEvents.kt <<'EOF'
package shop.checkout

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

data class PaymentRequested(val orderId: String, val cents: Long)

class CheckoutEvents {
    private val _requests = MutableSharedFlow<PaymentRequested>(extraBufferCapacity = 8)
    val requests: SharedFlow<PaymentRequested> = _requests

    fun send(event: PaymentRequested) {
        _requests.tryEmit(event)
    }
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/PaymentStatusStore.kt <<'EOF'
package shop.checkout

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

enum class PaymentStatus { Idle, Pending, Paid, Failed }

class PaymentStatusStore {
    private val _status = MutableStateFlow(PaymentStatus.Idle)
    val status: StateFlow<PaymentStatus> = _status

    fun set(value: PaymentStatus) {
        _status.value = value
    }
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/PaymentProcessor.kt <<'EOF'
package shop.checkout

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

class PaymentProcessor(
    private val events: CheckoutEvents,
    private val gateway: PaymentGateway,
    private val store: PaymentStatusStore,
) {
    fun start(scope: CoroutineScope) {
        scope.launch {
            events.requests.collect { request ->
                store.set(PaymentStatus.Pending)
                val ok = gateway.charge(request.orderId, request.cents)
                store.set(if (ok) PaymentStatus.Paid else PaymentStatus.Failed)
            }
        }
    }
}
EOF

put feature/checkout/src/main/kotlin/shop/checkout/CheckoutViewModel.kt <<'EOF'
package shop.checkout

import kotlinx.coroutines.flow.StateFlow

class CheckoutViewModel(
    private val events: CheckoutEvents,
    store: PaymentStatusStore,
) {
    val status: StateFlow<PaymentStatus> = store.status

    fun onPayClicked(orderId: String, cents: Long) {
        events.send(PaymentRequested(orderId, cents))
    }
}
EOF

commit "Process payments off the view model through an event queue"
