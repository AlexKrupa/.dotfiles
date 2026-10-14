#!/usr/bin/env bash
# Usage: notes-app.sh <repo-dir>
# A small Kotlin notes app on `main`, 1 commit. Base repo for all draft-ticket evals.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Notes

Android app to write, tag, and search notes. Notes are stored only on the device.
EOF

put app/src/main/kotlin/notes/Note.kt <<'EOF'
package notes

data class Note(val id: Long, val title: String, val body: String, val tags: List<String>, val createdAt: Long)
EOF

put app/src/main/kotlin/notes/NoteRepository.kt <<'EOF'
package notes

class NoteRepository(private val dao: NoteDao) {
    fun all(): List<Note> = dao.loadAll()
    fun search(query: String): List<Note> = dao.loadAll().filter { query in it.title || query in it.body }
}
EOF

put app/src/main/kotlin/notes/settings/SettingsScreen.kt <<'EOF'
package notes.settings

@Composable
fun SettingsScreen(onBack: () -> Unit) {
    Column {
        SettingsSection(title = "Appearance") { FontSizeRow() }
        SettingsSection(title = "Data") { ClearTrashRow() }
    }
}
EOF
commit "Add notes app"
