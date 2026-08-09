#!/usr/bin/env bash
# Symlink shared local files from the main checkout into a newly created worktree.
# Runs on herdr's worktree.created event. Always exits 0, so herdr does not mark
# the event failed when there is nothing to do.
#
# Field names come from herdr's API schema. The worktree_created event holds
# .worktree.path (the new checkout) and .workspace.worktree.repo_root (the main
# checkout). The jq filters walk the whole payload, so only the leaf key matters.
#
# Written for bash 3.2, the version macOS ships.

[ -n "${HERDR_PLUGIN_EVENT_JSON:-}" ] || exit 0
command -v jq >/dev/null || exit 0

wt=$(printf '%s' "$HERDR_PLUGIN_EVENT_JSON" |
  jq -r '[.. | objects | .path? // empty] | first // empty')
main=$(printf '%s' "$HERDR_PLUGIN_EVENT_JSON" |
  jq -r '[.. | objects | .repo_root? // empty] | first // empty')

[ -d "$wt" ] || exit 0
[ -d "$main" ] || exit 0
[ "$wt" != "$main" ] || exit 0

# The global list, then this repo's own additions. Both are optional, and the
# lists add up rather than replace. A path listed twice is harmless: the first
# pass creates the link and the second sees it already exists.
for list in "${HERDR_PLUGIN_ROOT:-$(dirname "$0")}/links.conf" "$main/.herdr-links"; do
  [ -f "$list" ] || continue

  # `read` with default IFS trims surrounding whitespace. The `|| [ -n "$line" ]`
  # keeps a final line that has no trailing newline.
  while read -r line || [ -n "$line" ]; do
    path=${line%%#*}                          # drop comments
    path=${path%"${path##*[![:space:]]}"}     # drop whitespace the comment left
    [ -n "$path" ] || continue

    case $path in
      /* | *..*) continue ;;                  # no absolute paths, no traversal
    esac

    [ -e "$main/$path" ] || continue           # nothing to link
    [ -e "$wt/$path" ] && continue             # never overwrite

    mkdir -p "$(dirname "$wt/$path")"
    ln -s "$main/$path" "$wt/$path"
  done < "$list"
done

exit 0
