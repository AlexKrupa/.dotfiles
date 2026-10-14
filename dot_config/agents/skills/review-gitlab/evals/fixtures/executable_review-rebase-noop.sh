#!/usr/bin/env bash
# Usage: review-rebase-noop.sh <repo-dir>
# review-base.sh, then main gets a new file, and the author rebases `tags-model` onto it with no
# content change and force-pushes. The local refs stay as before a fetch. Prints event= with the
# pushed event.
# Tests: one Info line "no content change", no review, no update in the report.
"$(dirname "$0")/review-base.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
base=$(git rev-parse main)
reviewed=$(git rev-parse refs/eval/reviewed)

git worktree add -q --detach "$1.author" main
cd "$1.author"
put app/src/main/kotlin/notes/Sync.kt <<'EOF'
package notes

class Sync
EOF
commit "Add Sync"
main2=$(git rev-parse HEAD)
git push -q origin HEAD:main
git checkout -q --detach "$reviewed"
git rebase -q "$main2"
new=$(git rev-parse HEAD)
git push -q -f origin HEAD:tags-model
cd "$1"
git worktree remove --force "$1.author"
git update-ref refs/remotes/origin/main "$base"
git update-ref refs/remotes/origin/tags-model "$reviewed"

jq -nc --arg ob "$base" --arg oh "$reviewed" --arg nb "$main2" --arg nh "$new" \
  --arg u https://gitlab.example.com/notes/app/-/merge_requests/11 \
  '{kind: "pushed", iid: 11, title: "Add Tag model", url: $u, actor: "",
    detail: "pushed \($nh[0:8])", branch: "tags-model",
    old_base: $ob, old_head: $oh, new_base: $nb, new_head: $nh}' | sed 's/^/event=/'
