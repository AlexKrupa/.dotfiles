#!/usr/bin/env bash
# Usage: fan-out.sh <repo-dir>
# Branch `feat/catalog` vs `main` (with origin) with 23 changed files, so the skill must dispatch
# its three review agents. One seeded defect per agent:
#   defect:    src/catalog/Paging.kt:4     integer division drops the last partial page
#   docs:      src/catalog/CatalogLog.kt:4 println - violates CONTRIBUTING.md "Logging"
#   structure: src/catalog/Strings.kt:3    `clip` duplicates `truncate` in src/util/Text.kt:4
source "$(dirname "$0")/lib.sh"
init_repo "$1"

put CONTRIBUTING.md <<'EOF'
# Contributing

## Logging

Log through `util.Log`. Do not use `println`.
EOF

put src/util/Log.kt <<'EOF'
package util

object Log {
    fun d(message: String) = System.err.println("D: $message")
}
EOF

put src/util/Text.kt <<'EOF'
package util

/** Cuts [text] to [max] characters and adds "..." when it was longer. */
fun truncate(text: String, max: Int): String =
    if (text.length <= max) text else text.take(max) + "..."
EOF

commit "Initial utils"
add_origin

git switch -q -c feat/catalog
for i in $(seq -w 1 19); do
  put "src/catalog/model/Item$i.kt" <<EOF
package catalog.model

data class Item$i(val id: String, val title: String, val priceCents: Long)
EOF
done

put src/catalog/Paging.kt <<'EOF'
package catalog

/** Number of pages needed to show [total] items, [size] per page. */
fun pageCount(total: Int, size: Int): Int = total / size
EOF

put src/catalog/CatalogLog.kt <<'EOF'
package catalog

fun logPage(page: Int, of: Int) {
    println("catalog page $page of $of")
}
EOF

put src/catalog/Strings.kt <<'EOF'
package catalog

fun clip(s: String, n: Int): String = if (s.length <= n) s else s.take(n) + "..."
EOF

put src/catalog/Catalog.kt <<'EOF'
package catalog

import catalog.model.Item01

class Catalog(private val items: List<Item01>, private val pageSize: Int) {
    fun page(index: Int): List<String> {
        logPage(index, pageCount(items.size, pageSize))
        return items.drop(index * pageSize).take(pageSize).map { clip(it.title, 20) }
    }
}
EOF
commit "Add catalog"
