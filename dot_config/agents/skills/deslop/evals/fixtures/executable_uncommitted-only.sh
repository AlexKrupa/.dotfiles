#!/usr/bin/env bash
# Usage: uncommitted-only.sh <repo-dir>
# Branch `feat/cache` vs `main`, 1 commit, plus uncommitted changes. The prompt asks for the
# uncommitted changes only.
#   docs/committed.md   slop in the branch commit - out of scope, must not change.
#   src/Cache.kt        committed code. The unstaged edit adds 1 what-comment and 1 why-comment
#                       (CACHE-77) with slop. Delete the what-comment, keep the why. Code is out
#                       of scope.
#   docs/cache.md       untracked, slop. Facts to keep: 512 entries, 15 minutes, `Cache.clear()`.
#   docs/staged.md      staged new file with slop. In scope (the working tree vs HEAD has it). Its
#                       index entry must not change.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'EOF'
# Cache
EOF
commit "Initial commit"

git switch -q -c feat/cache
put src/Cache.kt <<'EOF'
package cache

class Cache(private val capacity: Int) {
    private val entries = LinkedHashMap<String, String>(capacity, 0.75f, true)

    fun put(key: String, value: String) {
        entries[key] = value
        if (entries.size > capacity) entries.remove(entries.keys.first())
    }
}
EOF
put docs/committed.md <<'EOF'
# Committed notes

This robust cache genuinely leverages an LRU map.
EOF
commit "Add cache"

put src/Cache.kt <<'EOF'
package cache

class Cache(private val capacity: Int) {
    // Access order, not insertion order: the robust eviction below needs the least recently
    // used key first (CACHE-77).
    private val entries = LinkedHashMap<String, String>(capacity, 0.75f, true)

    fun put(key: String, value: String) {
        // Importantly, this seamlessly puts the value into the map.
        entries[key] = value
        if (entries.size > capacity) entries.remove(entries.keys.first())
    }

    fun clear() = entries.clear()
}
EOF
put docs/cache.md <<'EOF'
# Cache

It's worth noting that the cache serves as a robust store — it holds at most 512 entries.
Entries expire after 15 minutes. `Cache.clear()` genuinely removes all entries.
EOF
put docs/staged.md <<'EOF'
# Staged notes

This seamless layer leverages the cache.
EOF
git add docs/staged.md

echo "base=$(git rev-parse main)"
