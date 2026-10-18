#!/usr/bin/env bash
# Usage: clean-branch.sh <repo-dir>
# Branch `feat/retry` vs `main`, 2 commits, no slop. The skill must change nothing.
#   src/Retry.kt     1 why-comment (NET-31) that follows the comment rules.
#   docs/retry.md    plain text with facts. `seamless_fallback` is a config key in a code block -
#                    code, out of scope, although it matches the slop patterns.
#   commit messages  plain, no slop.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'EOF'
# Client
EOF
commit "Initial commit"

git switch -q -c feat/retry
put src/Retry.kt <<'EOF'
package client

class Retry(val maxAttempts: Int = 3) {
    fun delayMillis(attemptIndex: Int): Long {
        // The server rate limit resets every 200 ms (NET-31). A shorter first delay gets a 429.
        return 200L shl attemptIndex
    }
}
EOF
commit "Add retry with a doubling delay"

put docs/retry.md <<'EOF'
# Retry configuration

The client retries a failed request up to 3 times. The first delay is 200 ms. The delay doubles
after each attempt.

Set the limit in `client.toml`:

```toml
[retry]
max_attempts = 3
seamless_fallback = true
```

If all attempts fail, the client throws `RetryExhaustedException`. The exception message has the
last HTTP status code.
EOF
commit "Document the retry configuration"

echo "base=$(git rev-parse main)"
