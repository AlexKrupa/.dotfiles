#!/usr/bin/env bash
# Usage: cross-file.sh <repo-dir>
# Branch `feat/sync-expiry` vs `main` (with origin).
#   src/session/TokenStore.kt:7  `expiresAt()` now returns seconds. The diff looks fine alone.
#                                SessionGuard.kt (not in the diff) still compares it with millis,
#                                so every session is expired at once.
#   src/test/session/TokenStoreTest.kt  mocks the `Token` data class (a value object).
# Uncommitted: untracked src/session/DebugDump.kt prints the token. It must be listed in the
# header, not audited.
source "$(dirname "$0")/lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Auth

Session and token handling.
EOF

put src/session/Token.kt <<'EOF'
package session

data class Token(val value: String, val issuedAtMillis: Long, val ttlMillis: Long)
EOF

put src/session/TokenStore.kt <<'EOF'
package session

class TokenStore(private var token: Token?) {
    /** Epoch time in millis when the current token expires, or 0 when there is no token. */
    fun expiresAt(): Long {
        val t = token ?: return 0
        return t.issuedAtMillis + t.ttlMillis
    }

    fun replace(newToken: Token) {
        token = newToken
    }
}
EOF

put src/session/SessionGuard.kt <<'EOF'
package session

class SessionGuard(private val store: TokenStore, private val nowMillis: () -> Long) {
    fun isExpired(): Boolean = nowMillis() >= store.expiresAt()
}
EOF

commit "Initial auth"
add_origin

git switch -q -c feat/sync-expiry
put src/session/TokenStore.kt <<'EOF'
package session

class TokenStore(private var token: Token?) {
    /** Epoch time in seconds when the current token expires, or 0 when there is no token. */
    fun expiresAt(): Long {
        val t = token ?: return 0
        return (t.issuedAtMillis + t.ttlMillis) / 1000
    }

    fun replace(newToken: Token) {
        token = newToken
    }
}
EOF

put src/sync/SyncPayload.kt <<'EOF'
package sync

import session.TokenStore

/** The sync API wants the expiry as epoch seconds. */
fun syncPayload(store: TokenStore): Map<String, Any> = mapOf("expires_at" to store.expiresAt())
EOF
commit "Send token expiry to the sync API"

put src/test/session/TokenStoreTest.kt <<'EOF'
package session

import io.mockk.every
import io.mockk.mockk
import kotlin.test.Test
import kotlin.test.assertEquals

class TokenStoreTest {
    @Test
    fun expiresAtIsInSeconds() {
        val token = mockk<Token>()
        every { token.issuedAtMillis } returns 10_000L
        every { token.ttlMillis } returns 5_000L

        assertEquals(15L, TokenStore(token).expiresAt())
    }
}
EOF
commit "Test token expiry"

put src/session/DebugDump.kt <<'EOF'
package session

fun dump(t: Token) = println("token=${t.value}")
EOF
