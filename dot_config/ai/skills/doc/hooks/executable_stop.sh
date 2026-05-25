#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"
init_hook

doc_updated=$(fm_date "$doc" "updated")
last_commit=$(git log -1 --format=%cs 2>/dev/null || true)
[ -z "$doc_updated" ] || [ -z "$last_commit" ] && exit 0

if [[ "$last_commit" > "$doc_updated" ]]; then
  printf 'Active doc %s has activity since last sync (%s -> %s). Consider running /doc-sync.\n' \
    "$(basename "$doc")" "$doc_updated" "$last_commit"
fi
