#!/usr/bin/env bash
# Usage: risky-code.sh <repo-dir>
# Branch `feat/user-lookup` vs `main` (with origin). The repo has no docs.
#   src/db/UserRepo.kt:7       SQL built from the raw `name` query parameter - injection
#   src/cache/UserCache.kt:14  HashMap written from HTTP worker threads - data race
#   src/cache/UserCache.kt:17  requireNotNull on a non-null value - overcautious check
#   src/server/Server.kt:25    Thread.sleep inside a suspend function - blocks a dispatcher thread
# Correct code that must not be flagged:
#   src/db/UserRepo.kt:10      parameterized query
#   src/cache/UserCache.kt:13  AtomicLong counter
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put src/model/User.kt <<'EOF'
package model

data class User(val id: String, val name: String)
EOF

put src/db/Db.kt <<'EOF'
package db

interface Db {
    fun query(sql: String, vararg args: Any): List<Map<String, Any>>
}
EOF

commit "Initial model and db"
add_origin

git switch -q -c feat/user-lookup
put src/db/UserRepo.kt <<'EOF'
package db

import model.User

class UserRepo(private val db: Db) {
    fun findByName(name: String): List<User> =
        db.query("SELECT id, name FROM users WHERE name = '$name'").map(::toUser)

    fun load(id: String): User =
        db.query("SELECT id, name FROM users WHERE id = ?", id).map(::toUser).single()

    private fun toUser(row: Map<String, Any>) = User(row["id"] as String, row["name"] as String)
}
EOF

put src/cache/UserCache.kt <<'EOF'
package cache

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import model.User

class UserCache(private val load: (String) -> User) {
    private val users = ConcurrentHashMap<String, User>()
    private val hitCounts = HashMap<String, Int>()
    private val requests = AtomicLong()

    fun get(id: String): User {
        requests.incrementAndGet()
        hitCounts[id] = (hitCounts[id] ?: 0) + 1
        return users.computeIfAbsent(id) { key ->
            val user = load(key)
            requireNotNull(user) { "load returned null for $key" }
        }
    }

    fun requestCount(): Long = requests.get()

    fun hits(id: String): Int = hitCounts[id] ?: 0
}
EOF

put src/server/Server.kt <<'EOF'
package server

import cache.UserCache
import db.UserRepo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class Server(private val repo: UserRepo, private val scope: CoroutineScope) {
    private val cache = UserCache(repo::load)

    /** The HTTP layer calls this on its worker threads. [query] is the raw `name` parameter. */
    fun onSearch(query: String, respond: (String) -> Unit) {
        scope.launch(Dispatchers.Default) {
            respond(search(query))
        }
    }

    /** The HTTP layer calls this on its worker threads. */
    fun onGet(id: String): String = cache.get(id).name

    private suspend fun search(query: String): String {
        val users = repo.findByName(query)
        if (users.isEmpty()) {
            Thread.sleep(200) // Slows down user enumeration.
        }
        return users.joinToString { it.name }
    }
}
EOF
commit "Add user lookup"
