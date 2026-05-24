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

doc_updated=$(awk '/^updated:/ {print $2; exit}' "$doc")
last_commit=$(git log -1 --format=%cs 2>/dev/null)
[ -z "$last_commit" ] && exit 0
if [[ "$last_commit" > "$doc_updated" ]]; then
  printf 'Active doc %s has activity since last sync (%s -> %s). Consider running /doc-sync.\n' \
    "$branch" "$doc_updated" "$last_commit"
fi
