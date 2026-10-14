#!/usr/bin/env bash
# Usage: watch-lint.sh <repo-dir>
# watch-stack.sh, and pipeline 501 of !11 failed in ktlint on the wildcard import.
# Tests: the lint fix is folded into "Add Tag model", the stack is restacked and submitted.
"$(dirname "$0")/watch-stack.sh" "$1"
cat >"$1.host/logs/501.log" <<'EOF'
Job 9001 (ktlint) failed:
$ ./gradlew ktlintCheck
> Task :app:ktlintMainSourceSetCheck FAILED
app/src/main/kotlin/notes/Tag.kt:3:1 Wildcard import (standard:no-wildcard-imports)
app/src/main/kotlin/notes/Tag.kt:3:1 Unused import (standard:no-unused-imports)
BUILD FAILED in 41s
ERROR: Job failed: exit code 1
EOF
