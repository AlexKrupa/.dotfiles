#!/usr/bin/env bash
# Usage: branch-slop.sh <repo-dir>
# Branch `feat/sync-retry` vs `main` (with origin), 3 commits. Seeded slop:
#   src/sync/RetryPolicy.kt  marketing KDoc, 3 comments that restate the code, 1 why-comment
#                            (SYNC-412) to keep. `robustLabel()` and the em-dash in its string
#                            literal are code - out of scope.
#   src/sync/SyncLoop.kt     new what-comment. The "Legacy" comment is on an unchanged line - keep.
#   docs/sync.md             banned words, filler, em-dashes, title-case headings, a line over 100
#                            chars. Facts to keep: 30 seconds, version 2.4, maxAttempts 0, the link.
#   commit 1 message         banned words and an em-dash. Facts to keep: 30 s, SYNC-412.
#   README.md                slop outside the diff - must not change.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'EOF'
# Sync client

This robust client leverages a battle-tested protocol to seamlessly sync your data.
EOF

put src/sync/SyncClient.kt <<'EOF'
package sync

interface SyncClient {
    fun pull()
}
EOF

put src/sync/SyncLoop.kt <<'EOF'
package sync

class SyncLoop(private val client: SyncClient) {
    // Legacy: this robust loop leverages the old client API.
    fun runOnce() {
        client.pull()
    }
}
EOF

commit "Initial sync client"
add_origin
git switch -q -c feat/sync-retry

put src/sync/RetryPolicy.kt <<'EOF'
package sync

import kotlin.math.min

/**
 * This class serves as a robust, battle-tested retry policy that seamlessly handles
 * transient failures — it leverages exponential backoff to streamline recovery.
 */
class RetryPolicy(private val maxAttempts: Int, private val baseDelayMs: Long) {

    // Initialize the attempt counter to zero.
    private var attempt = 0

    // Check if we can retry.
    fun canRetry(): Boolean = attempt < maxAttempts

    fun nextDelayMs(): Long {
        attempt++
        // Cap at 30 s: the sync server drops connections that are idle for more than 30 s (SYNC-412).
        return min(baseDelayMs shl attempt, 30_000L)
    }

    // Returns a robust, human-friendly label for the current attempt.
    fun robustLabel(): String = "retry — attempt $attempt of $maxAttempts"
}
EOF
git add -A
git commit -q -F - <<'EOF'
Add robust retry policy that seamlessly leverages exponential backoff

This commit genuinely streamlines sync recovery — it's worth noting that the delay is capped
at 30 s because the server drops idle connections (SYNC-412).
EOF

put docs/sync.md <<'EOF'
# Sync Retry Behavior

## Overview

It's worth noting that the sync client now leverages a robust retry policy — this genuinely streamlines recovery from flaky networks. Importantly, the policy serves as the single place to tune retries.

## How It Works

The policy waits `baseDelayMs * 2^attempt` milliseconds between attempts, capped at 30 seconds.
Since version 2.4, the cap also applies to manual syncs. See the
[retry design](https://example.com/sync/retry-design) for details.

Set `maxAttempts` to 0 to disable retries.
EOF
commit "Add sync guide"

put src/sync/SyncLoop.kt <<'EOF'
package sync

class SyncLoop(private val client: SyncClient, private val policy: RetryPolicy) {
    // Legacy: this robust loop leverages the old client API.
    fun runOnce() {
        client.pull()
    }

    // Loop until the sync succeeds or the retries run out.
    fun runWithRetry() {
        while (true) {
            try {
                client.pull()
                return
            } catch (e: java.io.IOException) {
                if (!policy.canRetry()) throw e
                Thread.sleep(policy.nextDelayMs())
            }
        }
    }
}
EOF
commit "Use retry policy in sync loop"

echo "base=$(git rev-parse main)"
