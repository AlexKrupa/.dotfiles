#!/usr/bin/env bash
# Usage: re-review.sh <repo-dir>
# Branch `feat/csv-import` vs `main` (with origin), plus a previous same-day report with:
#   H1 src/CsvImport.kt:11 - malformed row crashes the import (not fixed)
#   M1 src/Totals.kt:4     - fold reinvents sumOf (fixed by the last commit)
#   L1 src/Totals.kt:6     - runningTotals has no callers (fixed: removed)
# The fix commit:
#   - adds `println` at src/Totals.kt:5 - a new finding.
#   - removes `runningTotals`, the only caller of `addAmounts` at src/Money.kt:3. Money.kt is not
#     edited, so only the one-hop rule finds the now-unused symbol.
#   - fixes a comment typo in src/CsvImport.kt - a file with no behavior change.
# Prints `previous_report=<path>` on stdout.
source "$(dirname "$0")/lib.sh"
skill_dir="$(cd "$(dirname "$0")/../.." && pwd)"
init_repo "$1"

put README.md <<'EOF'
# Ledger

Imports CSV files of `name,amount` rows and sums them.
EOF

put src/Row.kt <<'EOF'
package csv

data class Row(val name: String, val amount: Int)
EOF

commit "Initial ledger"
add_origin

git switch -q -c feat/csv-import
put src/CsvImport.kt <<'EOF'
package csv

import java.io.File

// Input files come from users and are not validated upsteam.
fun importFile(path: String): List<Row> =
    File(path).readLines().map { parseRow(it) }

fun parseRow(line: String): Row {
    val parts = line.split(",")
    return Row(parts[0], parts[1].toInt())
}
EOF

put src/Totals.kt <<'EOF'
package csv

fun total(rows: List<Row>): Int =
    rows.map { it.amount }.fold(0) { acc, x -> acc + x }

fun runningTotals(rows: List<Row>): List<Int> =
    rows.runningFold(0) { acc, r -> addAmounts(acc, r.amount) }.drop(1)
EOF

put src/Money.kt <<'EOF'
package csv

fun addAmounts(a: Int, b: Int): Int = Math.addExact(a, b)
EOF
commit "Add CSV import and totals"

report="$("$skill_dir/report-path.sh" main)"
put "$report" <<EOF
# Review: feat/csv-import (vs origin/main)

**TL;DR:** Fix then merge. A malformed CSV row crashes the whole import (\`H1\`).

**Counts:** 0 critical, 1 high, 1 medium, 1 low

---

- Author: Test Dev
- Base: origin/main (default-branch)
- Commits: 1 Files: 3 +22/-0
- Uncommitted: no
- Generated: $(date +%F)
- Convention docs consulted: README.md

## Review guide

1. \`src/CsvImport.kt\` - new import entry point, has \`H1\`

Then: \`src/Totals.kt\` sum helpers, has \`M1\` and \`L1\`. \`src/Money.kt\` one-line helper.

## Findings

### High

- **H1** \`src/CsvImport.kt:11\` - malformed row crashes the import
  What: A line with fewer than two fields throws \`IndexOutOfBoundsException\`, and a non-numeric
  amount throws \`NumberFormatException\`. Input files come from users. Fix: Validate the field
  count and use \`toIntOrNull()\`. Skip or report bad rows.

### Medium

- **M1** \`src/Totals.kt:4\` - \`fold\` reinvents \`sumOf\`
  What: \`map { }.fold(0) { acc, x -> acc + x }\` is \`sumOf { it.amount }\`. Fix: Use
  \`rows.sumOf { it.amount }\`.

### Low

- **L1** \`src/Totals.kt:6\` - \`runningTotals\` has no callers
  What: Nothing in the repo calls \`runningTotals\`. Fix: Remove it until a caller needs it.
EOF

put src/Totals.kt <<'EOF'
package csv

fun total(rows: List<Row>): Int {
    val sum = rows.sumOf { it.amount }
    println("total=$sum")
    return sum
}
EOF
sed -i '' 's/validated upsteam/validated upstream/' src/CsvImport.kt
commit "Address review: use sumOf, remove runningTotals"

printf 'previous_report=%s\n' "$report"
