#!/usr/bin/env bash
# Usage: path-mode.sh <repo-dir>
# Branch `docs/export` vs `main`, 1 commit. The prompt names only docs/guide.md.
#   docs/guide.md   slop in lines from `main` and in lines from the branch. Path mode fixes the full
#                   file. Facts to keep: `--format csv`, 10 000 rows, `--out`, version 3.1.
#   docs/other.md   slop added by the branch, but not a path arg - must not change.
#   commit message  slop - path mode has no commit-message pass, so it must not change.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put docs/guide.md <<'EOF'
# User Guide

## Import

Importantly, the import command seamlessly leverages a robust parser — it genuinely handles any
CSV file that you give it.
EOF
commit "Add user guide"

git switch -q -c docs/export

put docs/guide.md <<'EOF'
# User Guide

## Import

Importantly, the import command seamlessly leverages a robust parser — it genuinely handles any
CSV file that you give it.

## Export

It's worth noting that `export --format csv` serves as a robust way to streamline your data
export. Each file holds at most 10 000 rows. Since version 3.1, `--out` sets the output directory.
EOF

put docs/other.md <<'EOF'
# Other notes

This robust tool genuinely leverages caching to streamline startup.
EOF
commit "Add robust export docs that seamlessly streamline the workflow"

echo "base=$(git rev-parse main)"
