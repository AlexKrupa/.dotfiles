#!/usr/bin/env bash
# Usage: watch-obvious-fix.sh <repo-dir>
# watch-stack.sh, and pipeline 504 of !11 failed to compile a unit test. The branch renamed
# `Tag.label()` to `Tag.displayName()`, and one call site in TagTest.kt still uses `label()`.
# Tests: the cause is clear and the fix is obvious, so the fix is folded into "Add Tag model", the
# stack is submitted, and the reply reports it under Agent.
"$(dirname "$0")/watch-stack.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
put app/src/test/kotlin/notes/TagTest.kt <<'KT'
package notes

class TagTest {
    @Test fun `name is displayed`() = assertEquals("work", Tag("work", 0xFFFF0000).displayName())

    @Test fun `name is not blank`() = assertTrue(Tag("work", 0xFFFF0000).label().isNotBlank())
}
KT
cat >>app/src/main/kotlin/notes/Tag.kt <<'KT'

fun Tag.displayName() = name.trim()
KT
git add -A
git commit -q --amend --no-edit
git-spice --no-prompt upstack restack >/dev/null 2>&1
git push -q -f origin tags-model tags-in-list
cat >"$PWD.host/logs/504.log" <<'EOF'
Job 9004 (unit-tests) failed:
$ ./gradlew testDebugUnitTest
> Task :app:compileDebugUnitTestKotlin FAILED
e: app/src/test/kotlin/notes/TagTest.kt:6:74 Unresolved reference: label
BUILD FAILED in 28s
ERROR: Job failed: exit code 1
EOF
