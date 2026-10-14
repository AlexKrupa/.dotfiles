#!/usr/bin/env bash
# Usage: one-way-door.sh <repo-dir>
# Branch `feat/profile-v2` vs `main` (with origin). The repo has no docs.
# High-impact changes:
#   src/db/migrations/V7__move_address.sql  drops users.address after a copy - data deletion
#   src/cache/CacheKeys.kt                  3 cache key formats change - one item, not three
#   src/prefs/Settings.kt                   stored field fontSize renamed to textScale, no
#                                           @SerialName or migration - also a defect finding
# Changes that must not be high-impact:
#   src/api/schema.graphqls                 new nullable field - backward compatible
#   src/profile/ProfileFormatter.kt         private formatting change
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put src/prefs/Settings.kt <<'EOF'
package prefs

import kotlinx.serialization.Serializable

@Serializable
data class Settings(
    val theme: String = "system",
    val fontSize: Int = 14,
)
EOF

put src/prefs/SettingsStore.kt <<'EOF'
package prefs

import java.io.File
import kotlinx.serialization.json.Json

/** Keeps the user's settings in a JSON file on the device. */
class SettingsStore(private val file: File) {
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): Settings =
        if (file.exists()) json.decodeFromString(file.readText()) else Settings()

    fun save(settings: Settings) = file.writeText(json.encodeToString(Settings.serializer(), settings))
}
EOF

put src/cache/CacheKeys.kt <<'EOF'
package cache

object CacheKeys {
    fun profile(id: String) = "profile:$id"
    fun avatar(id: String) = "avatar:$id"
    fun friends(id: String) = "friends:$id"
}
EOF

put src/db/migrations/V6__create_users.sql <<'EOF'
CREATE TABLE users (
    id      TEXT PRIMARY KEY,
    name    TEXT NOT NULL,
    address TEXT
);
EOF

put src/api/schema.graphqls <<'EOF'
type User {
  id: ID!
  name: String!
}

type Query {
  user(id: ID!): User
}
EOF

put src/profile/ProfileFormatter.kt <<'EOF'
package profile

class ProfileFormatter {
    fun title(name: String, city: String?): String = join(name, city)

    private fun join(name: String, city: String?): String =
        if (city == null) name else "$name, $city"
}
EOF

commit "Initial profile app"
add_origin

git switch -q -c feat/profile-v2

put src/prefs/Settings.kt <<'EOF'
package prefs

import kotlinx.serialization.Serializable

@Serializable
data class Settings(
    val theme: String = "system",
    val textScale: Float = 1.0f,
)
EOF

put src/cache/CacheKeys.kt <<'EOF'
package cache

object CacheKeys {
    fun profile(id: String) = "v2:profile:$id"
    fun avatar(id: String) = "v2:avatar:$id"
    fun friends(id: String) = "v2:friends:$id"
}
EOF

put src/db/migrations/V7__move_address.sql <<'EOF'
CREATE TABLE addresses (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    line    TEXT NOT NULL
);

INSERT INTO addresses (user_id, line)
SELECT id, address FROM users WHERE address IS NOT NULL;

ALTER TABLE users DROP COLUMN address;
EOF

put src/api/schema.graphqls <<'EOF'
type User {
  id: ID!
  name: String!
  nickname: String
}

type Query {
  user(id: ID!): User
}
EOF

put src/profile/ProfileFormatter.kt <<'EOF'
package profile

class ProfileFormatter {
    fun title(name: String, city: String?): String = join(name, city)

    private fun join(name: String, city: String?): String =
        if (city == null) name else "$name ($city)"
}
EOF

commit "Profile v2: address table, text scale, new cache format"
