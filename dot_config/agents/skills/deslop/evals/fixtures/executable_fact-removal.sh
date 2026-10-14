#!/usr/bin/env bash
# Usage: fact-removal.sh <repo-dir>
# Branch `docs/setup` vs `main` (with origin), 1 commit that adds docs/setup.md.
#   "Why this matters"  a full section of filler. Its deletion removes a section, so the skill
#                       must ask first: one grouped prompt at the end, section still in the file.
#   "Known issues"      a caveat with slop. Fix the wording, keep the facts: Android 12, 2 minutes,
#                       dex optimization.
# Prints `base=<sha of main>`.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"
allow_commits

put README.md <<'EOF'
# App

See docs/ for guides.
EOF
commit "Initial app"
add_origin
git switch -q -c docs/setup

put docs/setup.md <<'EOF'
# Setup

## Install

Run `./gradlew installDebug` to install the app on a connected device.

## Why this matters

In today's fast-paced world, a smooth setup experience is more important than ever. A great
setup process empowers developers to hit the ground running and unlock their full potential.

## Known issues

Note: on Android 12 and lower, the first install can take up to 2 minutes because of dex
optimization — this is a known issue and, honestly, it is genuinely not a big deal at all.
EOF
commit "Add setup guide"

echo "base=$(git rev-parse main)"
