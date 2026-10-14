#!/usr/bin/env bash
# Usage: reply-pasted.sh <repo-dir>
# A repo with one clean commit. Reply mode must not touch it: the snapshot before and after the
# run must be the same. The slop text is in the eval prompt.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Cache
EOF
commit "Initial commit"
