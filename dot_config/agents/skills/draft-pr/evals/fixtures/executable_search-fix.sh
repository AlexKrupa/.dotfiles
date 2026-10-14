#!/usr/bin/env bash
# Usage: search-fix.sh <repo-dir>
# notes-app.sh with a bare `origin`, then branch `fix/search-case` with 1 commit: the note search
# ignores letter case. No git-spice. Tests a small change: no review guide, no high-impact section,
# and branch preparation skipped. With a remote, `git-spice log` can find the trunk and initialize
# git-spice by itself, so `repo_unchanged` catches a skill that runs git-spice without the check.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
add_origin
git switch -q -c fix/search-case

put app/src/main/kotlin/notes/NoteRepository.kt <<'EOF'
package notes

class NoteRepository(private val dao: NoteDao) {
    fun all(): List<Note> = dao.loadAll()
    fun search(query: String): List<Note> = dao.loadAll().filter {
        it.title.contains(query, ignoreCase = true) || it.body.contains(query, ignoreCase = true)
    }
}
EOF
commit "Ignore letter case in note search"
