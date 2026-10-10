#!/usr/bin/env bash
# Usage: tags-stack.sh <repo-dir>
# notes-app.sh with a bare `origin`, git-spice on trunk `main`, and a stack of 2 branches:
# `tags-model` (Add Tag model + a fixup! commit) and `tags-in-list` (Show tags in the note list).
# `origin/main` has 1 commit that the local repo did not fetch. The current branch is `tags-model`.
# Tests: sync, restack, the fixup squash, the upstack restack, and Out of scope for the next branch.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
allow_commits
add_origin
git-spice --no-prompt repo init --trunk main --remote origin >/dev/null 2>&1

git switch -q -c tags-model
put app/src/main/kotlin/notes/Tag.kt <<'EOF'
package notes

data class Tag(val name: String, val color: Int)
EOF
commit "Add Tag model"
put app/src/main/kotlin/notes/Tag.kt <<'EOF'
package notes

data class Tag(val name: String, val color: Long)
EOF
git add -A
git commit -q --fixup=HEAD
git-spice --no-prompt branch track --base main >/dev/null 2>&1

git switch -q -c tags-in-list
put app/src/main/kotlin/notes/list/NoteListItem.kt <<'EOF'
package notes.list

@Composable
fun NoteListItem(note: Note, tags: List<Tag>) { Row { Text(note.title); tags.forEach { TagChip(it) } } }
EOF
commit "Show tags in the note list"
git-spice --no-prompt branch track --base tags-model >/dev/null 2>&1

# A commit on origin/main that the local repo does not have yet.
git clone -q "$PWD.origin.git" "$PWD.upstream"
(cd "$PWD.upstream" && put README.md <<<"# Notes app" && git add -A \
  && git commit -q -m "Rename README title" && git push -q)

git switch -q tags-model
