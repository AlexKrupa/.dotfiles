#!/usr/bin/env bash
# Builds a small Kotlin repo with a GitLab remote. Writes the fake review history of 8 merged MRs
# to <repo>.host/history.json for shims/glab. The planted topics:
# - AppLogger instead of Log.d/println: 3 MRs (101 applied suggestion, 104 changed, 107 no change)
# - no Android types in ViewModels, rule in docs/architecture.md: 2 MRs (102 changed, 106 general)
# - `when` instead of if-else: 2 MRs (105 author disagrees, 108 changed)
# - CHANGELOG entry: 1 MR (103) - seen once
# - noise: LGTM, a SonarQube bot, an off-by-one fix, a note from the MR author
set -euo pipefail
repo="$1"
here="$(cd "$(dirname "$0")" && pwd)"
git init -q -b main "$repo"
cd "$repo"
git remote add origin git@gitlab.example.com:acme/notes-app.git
mkdir -p docs app/src/main/kotlin/ui
cat > CLAUDE.md <<'MD'
# notes-app

Android notes app. Build with `./gradlew assembleDebug`.
MD
cat > docs/architecture.md <<'MD'
# Architecture

ViewModels must not reference Android types (`Context`, `Resources`). Resolve strings in the UI.
MD
printf 'package ui\n\nclass NotesViewModel\n' > app/src/main/kotlin/ui/NotesViewModel.kt
git add -A
git -c user.name=dev -c user.email=dev@example.com -c commit.gpgsign=false commit -q -m Init
mkdir -p "$repo.host"
cp "$here/history.json" "$repo.host/"
