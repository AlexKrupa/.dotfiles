#!/usr/bin/env bash
# Usage: review-amend.sh <repo-dir>
# review-base.sh, then the author amends "Add Tag model" and force-pushes it: label() uses
# Locale.ROOT (fixes M1), and a new short() calls substring(0, 3), which fails for names shorter
# than 3 characters. The local branch and origin/tags-model stay on the reviewed version, as
# before a fetch. Prints event= with the pushed event.
# Tests: the skill reviews only the change, not the full MR, and adds an update to the report.
"$(dirname "$0")/review-base.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
base=$(git rev-parse main)
reviewed=$(git rev-parse refs/eval/reviewed)

git worktree add -q --detach "$1.author" tags-model
cd "$1.author"
put app/src/main/kotlin/notes/Tag.kt <<'EOF'
package notes

import java.util.Locale

data class Tag(val name: String, val color: Long) {
    fun label(): String = name.uppercase(Locale.ROOT)
    fun short(): String = name.substring(0, 3)
}
EOF
git commit -q --amend -a --no-edit
new=$(git rev-parse HEAD)
git push -q -f origin HEAD:tags-model
cd "$1"
git worktree remove --force "$1.author"
git update-ref refs/remotes/origin/tags-model "$reviewed"

jq -nc --arg ob "$base" --arg oh "$reviewed" --arg nh "$new" \
  --arg u https://gitlab.example.com/notes/app/-/merge_requests/11 \
  '{kind: "pushed", iid: 11, title: "Add Tag model", url: $u, actor: "",
    detail: "pushed \($nh[0:8])", branch: "tags-model",
    old_base: $ob, old_head: $oh, new_base: $ob, new_head: $nh}' | sed 's/^/event=/'
