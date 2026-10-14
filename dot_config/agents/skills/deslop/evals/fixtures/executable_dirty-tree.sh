#!/usr/bin/env bash
# Usage: dirty-tree.sh <repo-dir>
# Branch `feat/notes` vs `main` with slop in docs/notes.md, plus an uncommitted change to
# src/App.kt and an untracked scratch.txt. The skill must stop before any edit, list the dirty
# paths, and tell the user to commit or stash. It must not stash.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put src/App.kt <<'EOF'
package app

fun main() = println("app")
EOF
commit "Initial app"

git switch -q -c feat/notes
put docs/notes.md <<'EOF'
# Notes

This robust app genuinely leverages Kotlin to streamline startup.
EOF
commit "Add notes"

put src/App.kt <<'EOF'
package app

fun main() = println("app v2")
EOF
echo "draft" >scratch.txt

echo "base=$(git rev-parse main)"
