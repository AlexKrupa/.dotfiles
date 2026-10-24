#!/usr/bin/env bash
# Usage: settings-ui-change.sh <repo-dir>
# notes-app.sh, then branch `feature/settings-export-row` adds an export row to Settings > Data.
# No screenshot tests, no remote, and no git-spice. Tests: a UI change with no media gets a capture
# suggestion and starts no capture. When the prompt asks for capture, the agent uses the
# android-capture skill.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"

git switch -q -c feature/settings-export-row
put app/src/main/kotlin/notes/settings/SettingsScreen.kt <<'EOT'
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
EOT
commit "Add export row to Settings > Data"
