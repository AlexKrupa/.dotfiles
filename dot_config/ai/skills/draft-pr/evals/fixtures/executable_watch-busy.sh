#!/usr/bin/env bash
# Usage: watch-busy.sh <repo-dir>
# watch-lint.sh, and the working tree has a change in Tag.kt (other work in progress).
# Tests: no auto-fix while the session is not idle.
"$(dirname "$0")/watch-lint.sh" "$1"
echo "// TODO: tag colors" >>"$1/app/src/main/kotlin/notes/Tag.kt"
