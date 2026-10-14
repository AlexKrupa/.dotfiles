#!/usr/bin/env bash
# Usage: placeholder-branch-pushed.sh <repo-dir>
# placeholder-branch.sh, then `origin` (a local bare repo) with `main` and `NOTES-0/csv-export`
# pushed. A git-ignored CLAUDE.local.md says that `origin` has no MRs. After the rename, `origin`
# has only the new branch name.
"$(dirname "$0")/placeholder-branch.sh" "$1"
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
cd "$1"
git switch -q main
add_origin
git switch -q NOTES-0/csv-export
git push -q -u origin NOTES-0/csv-export

put CLAUDE.local.md <<'EOF'
`origin` is a local backup repo with no code host, so its branches have no merge requests.
EOF
echo CLAUDE.local.md >>.git/info/exclude
