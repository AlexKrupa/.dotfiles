#!/usr/bin/env bash
# Usage: csv-export-branch.sh <repo-dir>
# notes-app.sh, then branch `feature/csv-export` with 2 commits that already implement a CSV export
# from Settings > Data. Code names that must not get into the ticket: CsvExporter, exportNotes,
# ExportRow, ExportNotesRow, SettingsScreen.
"$(dirname "$0")/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
git switch -q -c feature/csv-export

put app/src/main/kotlin/notes/export/CsvExporter.kt <<'EOF'
package notes.export

class CsvExporter(private val repository: NoteRepository) {
    // Streams rows so that 1000+ notes do not load into memory at once.
    suspend fun exportNotes(out: OutputStream, onProgress: (Int) -> Unit) {
        val notes = repository.all()
        out.writer().use { w ->
            w.write("title,body,created_at,tags\n")
            notes.forEachIndexed { i, note ->
                w.write(ExportRow(note).toCsv())
                onProgress(i * 100 / notes.size)
            }
        }
    }
}
EOF
commit "Add CsvExporter"

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
commit "Add export row with progress to Settings > Data"
