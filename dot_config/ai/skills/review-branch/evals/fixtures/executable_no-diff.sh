#!/usr/bin/env bash
# Usage: no-diff.sh <repo-dir>
# Branch `feat/empty` points at the same commit as `main`. The skill must stop with no report.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Empty

Nothing here yet.
EOF
commit "Initial commit"
git switch -q -c feat/empty
