#!/usr/bin/env bash
# Usage: settings-export-row.sh <repo-dir>
# notes-app.sh, then a Paparazzi screenshot test of SettingsScreen and its reference image on
# `main`. Branch `feature/settings-export-row` adds an export row to Settings > Data and updates the
# test and the reference image. No remote and no git-spice. Tests: the description does not embed
# the reference image, tells that the image diff is in the changed files, and the reply has no
# capture suggestion.
"$(dirname "$0")/../../../draft-ticket/evals/fixtures/notes-app.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"

img=app/src/test/snapshots/images/notes.settings_SettingsScreenTest_dataSection.png
png() { mkdir -p "$(dirname "$img")"; printf '%s' "$1" | base64 --decode >"$img"; }

put app/src/test/kotlin/notes/settings/SettingsScreenTest.kt <<'EOF'
package notes.settings

class SettingsScreenTest {
    @get:Rule val paparazzi = Paparazzi()

    @Test fun dataSection() = paparazzi.snapshot { SettingsScreen(onBack = {}) }
}
EOF
png iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==
commit "Add screenshot test for Settings"

git switch -q -c feature/settings-export-row
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
put app/src/test/kotlin/notes/settings/SettingsScreenTest.kt <<'EOF'
package notes.settings

class SettingsScreenTest {
    @get:Rule val paparazzi = Paparazzi()

    @Test fun dataSection() = paparazzi.snapshot { SettingsScreen(onBack = {}, onExport = {}) }
}
EOF
png iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=
commit "Add export row to Settings > Data"
