#!/usr/bin/env bash
# Usage: review-base.sh <repo-dir>
# notes-app.sh with a bare `origin`, and MR !11 of Anna Dev: branch `tags-model` with 1 commit
# "Add Tag model". Tag.label() calls uppercase() with the default locale. The local branch is the
# reviewed version, also in refs/eval/reviewed. The review report under
# ~/.ai/<repo-slug>/reviews/ has finding M1 for it, and an open thread of the user on Tag.kt:6.
# Prints reviewed=, report=, and intro= with the prompt intro.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
allow_commits
add_origin

git switch -q -c tags-model
put app/src/main/kotlin/notes/Tag.kt <<'EOF'
package notes

import java.util.Locale

data class Tag(val name: String, val color: Long) {
    fun label(): String = name.uppercase(Locale.getDefault())
}
EOF
GIT_AUTHOR_NAME="Anna Dev" GIT_AUTHOR_EMAIL=anna@example.com commit "Add Tag model"
git push -q -u origin tags-model
git update-ref refs/eval/reviewed HEAD
reviewed=$(git rev-parse HEAD)
mr=https://gitlab.example.com/notes/app/-/merge_requests/11

report=$(~/.config/agents/bin/review-report-path.sh origin/main mr-11)
cat >"$report" <<EOF
# Review: tags-model (vs origin/main)

**TL;DR:** Fix then merge. \`Tag.label()\` depends on the default locale (\`M1\`).

**Counts:** 0 critical, 0 high, 1 medium, 0 low

---

- MR: $mr
- Author: Anna Dev
- Base: origin/main
- Reviewed head: $reviewed

## Findings

### Medium

- **M1** \`app/src/main/kotlin/notes/Tag.kt:6\` - \`uppercase(Locale.getDefault())\` depends on
  the default locale.
  What: In the Turkish locale, "i" becomes "İ". Fix: \`name.uppercase(Locale.ROOT)\`.

## Discussions

- You on \`Tag.kt:6\`: ask for \`Locale.ROOT\` (\`M1\`). Open.
EOF

echo "reviewed=$reviewed"
echo "report=$report"
echo "intro=/review-pr You reviewed MR !11 ($mr) of this repo: branch" \
  "\`tags-model\`, target \`main\`, remote \`origin\`, \`target_ref\` \`origin/main\`. The" \
  "reviewed HEAD is $reviewed. The report is $report."
