#!/usr/bin/env bash
# Usage: target-text.sh <repo-dir>
# Branch `feat/export` vs `main`, 1 commit, plus an untracked scratch.txt. The prompt names only
# the comments in src/Exporter.kt.
#   src/Exporter.kt  old comments (from main): 1 why-comment with no slop - must not change.
#                    1 what-comment with slop - delete or fix. Comments that the branch added:
#                    1 what-comment - delete, 1 why-comment (EXP-9) with slop - keep the fact.
#                    Code is out of scope.
#   docs/export.md   slop added by the branch, not in the target - must not change.
#   scratch.txt      untracked, slop - must not change. The skill must not stop on a dirty tree.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put src/Exporter.kt <<'EOF'
package export

class Exporter(private val rows: List<String>) {
    // Windows Excel reads a file as UTF-8 only if it starts with a BOM.
    private val bom = "﻿"

    // This robust function genuinely leverages a builder to export the rows.
    fun export(): String = bom + rows.joinToString("\n")
}
EOF
commit "Add exporter"

git switch -q -c feat/export
put src/Exporter.kt <<'EOF'
package export

class Exporter(private val rows: List<String>) {
    // Windows Excel reads a file as UTF-8 only if it starts with a BOM.
    private val bom = "﻿"

    // This robust function genuinely leverages a builder to export the rows.
    fun export(): String = bom + rows.joinToString("\n")

    // Count the rows.
    fun rowCount(): Int = rows.size

    // Importantly, the batch size seamlessly stays at 500 rows, because the import service
    // rejects larger requests (EXP-9).
    fun batches(): List<List<String>> = rows.chunked(500)
}
EOF
put docs/export.md <<'EOF'
# Export

This robust exporter genuinely streamlines CSV export.
EOF
commit "Add export batches"

echo "This robust draft leverages nothing." >scratch.txt

echo "base=$(git rev-parse main)"
