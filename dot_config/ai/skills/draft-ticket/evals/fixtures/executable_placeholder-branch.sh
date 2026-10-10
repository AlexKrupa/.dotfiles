#!/usr/bin/env bash
# Usage: placeholder-branch.sh <repo-dir>
# notes-app.sh, then a CLAUDE.md with the placeholder ticket id NOTES-0, and a `TODO(NOTES-0)` on
# `main` that belongs to other work. Branch `NOTES-0/csv-export`, tracked by git-spice, has 2
# commits with NOTES-0 in the message and adds a second `TODO(NOTES-0)`. After the rename, only the
# branch, its messages, and its TODO have the real id.
"$(dirname "$0")/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
allow_commits

put CLAUDE.md <<'EOF'
# Notes

Tickets are in Jira project NOTES. Before a ticket exists, the placeholder ticket id is `NOTES-0`.
EOF
put app/src/main/kotlin/notes/NoteRepository.kt <<'EOF'
package notes

class NoteRepository(private val dao: NoteDao) {
    fun all(): List<Note> = dao.loadAll()

    // TODO(NOTES-0): Search the tags too.
    fun search(query: String): List<Note> = dao.loadAll().filter { query in it.title || query in it.body }
}
EOF
commit "Add project instructions and search TODO"
git-spice repo init --trunk main >/dev/null 2>&1

git switch -q -c NOTES-0/csv-export
put app/src/main/kotlin/notes/export/CsvExporter.kt <<'EOF'
package notes.export

class CsvExporter(private val repository: NoteRepository) {
    // TODO(NOTES-0): Add the tags column.
    suspend fun exportNotes(out: OutputStream) {
        out.writer().use { w ->
            w.write("title,body,created_at\n")
            repository.all().forEach { w.write(ExportRow(it).toCsv()) }
        }
    }
}
EOF
commit "NOTES-0: Add CSV exporter"

put app/src/main/kotlin/notes/settings/SettingsScreen.kt <<'EOF'
package notes.settings

@Composable
fun SettingsScreen(onBack: () -> Unit, onExport: () -> Unit) {
    Column {
        SettingsSection(title = "Appearance") { FontSizeRow() }
        SettingsSection(title = "Data") {
            ClearTrashRow()
            ExportNotesRow(onClick = onExport)
        }
    }
}
EOF
commit "NOTES-0: Add export row to Settings > Data"
git-spice branch track --base main >/dev/null 2>&1
