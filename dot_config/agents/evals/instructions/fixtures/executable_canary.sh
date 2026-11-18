#!/usr/bin/env bash
# Usage: canary.sh <repo-dir>
# A repo with one commit and a README. Prints `base=<sha>`.
source "$(dirname "$0")/../../fixture-lib.sh"
init_repo "$1"
echo "# Canary" | put README.md
commit "Initial commit"
echo "base=$(git rev-parse HEAD)"
