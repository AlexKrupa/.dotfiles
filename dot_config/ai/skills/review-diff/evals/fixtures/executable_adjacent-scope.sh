#!/usr/bin/env bash
# Usage: adjacent-scope.sh <repo-dir>
# Stack: main (with origin) <- release/2.0 <- feat/order-notes (checked out).
# The eval passes `main` as the parent override, so the expected base is `main (override)`.
# The branch edits only a function body in OrderService.kt. Adjacent Simplicity radius:
#   src/orders/OrderRepository.kt  single-impl interface in the same module, direct callee
#                                  -> `(adjacent)` finding, medium at most, with the count
#   src/storage/*                  forwarding layer 2+ hops away -> must not be flagged
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Orders

Order storage and notes.
EOF

put src/orders/Order.kt <<'EOF'
package orders

data class Order(val id: String, val total: Long, val notes: List<String> = emptyList())
EOF

put src/orders/OrderRepository.kt <<'EOF'
package orders

interface OrderRepository {
    fun find(id: String): Order?
    fun save(order: Order)
}
EOF

put src/orders/StoreOrderRepository.kt <<'EOF'
package orders

import storage.KeyValueStore

class StoreOrderRepository(private val store: KeyValueStore) : OrderRepository {
    override fun find(id: String): Order? = store.read(id)?.let(OrderCodec::decode)

    override fun save(order: Order) = store.write(order.id, OrderCodec.encode(order))
}
EOF

put src/orders/OrderCodec.kt <<'EOF'
package orders

object OrderCodec {
    fun encode(order: Order): String =
        listOf(order.id, order.total.toString(), *order.notes.toTypedArray()).joinToString("\u001f")

    fun decode(raw: String): Order {
        val parts = raw.split("\u001f")
        return Order(parts[0], parts[1].toLong(), parts.drop(2))
    }
}
EOF

put src/storage/StoreBackend.kt <<'EOF'
package storage

interface StoreBackend {
    fun get(key: String): String?
    fun put(key: String, value: String)
}

class MapBackend : StoreBackend {
    private val map = mutableMapOf<String, String>()
    override fun get(key: String): String? = map[key]
    override fun put(key: String, value: String) { map[key] = value }
}
EOF

put src/storage/KeyValueStore.kt <<'EOF'
package storage

class KeyValueStore(private val backend: StoreBackend) {
    fun read(key: String): String? = backend.get(key)

    fun write(key: String, value: String) = backend.put(key, value)
}
EOF

put src/orders/OrderService.kt <<'EOF'
package orders

class OrderService(private val repo: OrderRepository) {
    fun total(id: String): Long? = repo.find(id)?.total

    fun addNote(id: String, note: String) {
        TODO("notes")
    }
}
EOF

commit "Initial orders"
add_origin

git switch -q -c release/2.0
put CHANGELOG.md <<'EOF'
# Changelog

## 2.0.0

- Order notes (planned).
EOF
commit "Start release 2.0"

git switch -q -c feat/order-notes
put src/orders/OrderService.kt <<'EOF'
package orders

class OrderService(private val repo: OrderRepository) {
    fun total(id: String): Long? = repo.find(id)?.total

    fun addNote(id: String, note: String): Boolean {
        val order = repo.find(id) ?: return false
        repo.save(order.copy(notes = order.notes + note.trim()))
        return true
    }
}
EOF
commit "Implement order notes"
