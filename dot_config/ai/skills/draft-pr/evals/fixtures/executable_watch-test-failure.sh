#!/usr/bin/env bash
# Usage: watch-test-failure.sh <repo-dir>
# watch-stack.sh, and pipeline 502 of !11 failed in a unit test.
# Tests: no fix, no push, a Needs you item with the cause.
"$(dirname "$0")/watch-stack.sh" "$1"
cat >"$1.host/logs/502.log" <<'EOF'
Job 9002 (unit-tests) failed:
$ ./gradlew testDebugUnitTest
TagTest > color is stored as ARGB FAILED
    org.opentest4j.AssertionFailedError: expected: <4294901760> but was: <-65536>
        at notes.TagTest.color is stored as ARGB(TagTest.kt:12)
42 tests completed, 1 failed
BUILD FAILED in 2m 3s
ERROR: Job failed: exit code 1
EOF
