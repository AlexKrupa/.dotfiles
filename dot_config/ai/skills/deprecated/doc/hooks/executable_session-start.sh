#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"
init_hook

branch=$(git branch --show-current 2>/dev/null || true)
title=$(awk '/^title:/ { sub(/^title:[[:space:]]*/, ""); print; exit }' "$doc")
todo=$(awk '
  /^## TODO/ { in_todo = 1; next }
  in_todo && /^## / { exit }
  in_todo && /^- \[[ -]\]/ { print }
' "$doc")
open=$(awk '
  /^## Open questions/ { in_open = 1; next }
  in_open && /^## / { exit }
  in_open && NF { print }
' "$doc")

printf 'Active design doc'
[ -n "$branch" ] && printf ' for branch `%s`' "$branch"
printf ' (open TODO + questions only; run /doc for full):\n\n'
[ -n "$title" ] && printf 'Title: %s\n' "$title"
printf 'Path: %s\n\n' "$doc"
if [ -n "$todo" ]; then
  printf 'Open TODO:\n%s\n\n' "$todo"
fi
if [ -n "$open" ]; then
  printf 'Open questions:\n%s\n' "$open"
fi
