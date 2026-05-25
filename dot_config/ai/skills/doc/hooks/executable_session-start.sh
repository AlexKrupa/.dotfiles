#!/usr/bin/env bash
set -e
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
branch=$(git branch --show-current 2>/dev/null) || exit 0
[ -z "$branch" ] && exit 0
docs_dir=$(bash "$(dirname "$0")/../bin/docs-dir.sh" 2>/dev/null) || exit 0
doc="$docs_dir/$branch.md"
[ -f "$doc" ] || exit 0
grep -q "^status: active" "$doc" || exit 0

printf 'Active design doc for branch %s (loaded automatically):\n\n' "$branch"
cat "$doc"
