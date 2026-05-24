#!/usr/bin/env bash
set -e
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
branch=$(git branch --show-current 2>/dev/null) || exit 0
[ -z "$branch" ] && exit 0
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
repo_name=$(basename "$(dirname "$common_dir")")
doc="$HOME/.ai/docs/$repo_name/$branch.md"
[ -f "$doc" ] || exit 0
grep -q "^status: active" "$doc" || exit 0

printf 'Active design doc exists at %s. Before compaction, run /doc-sync to capture decisions made this session.\n' "$doc"
