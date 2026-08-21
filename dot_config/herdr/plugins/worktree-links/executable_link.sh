#!/usr/bin/env bash
# Symlink shared local files from the main checkout into a newly created worktree.
# Always exits 0, so herdr does not mark the event failed when there is nothing
# to do.
#
# Field names come from herdr's API schema. The worktree_created event holds
# .worktree.path (the new checkout) and .workspace.worktree.repo_root (the main
# checkout). The jq filter walks the whole payload, so only the leaf key matters.

if ((BASH_VERSINFO[0] < 4)); then
  echo "worktree-links: needs bash 4+, got $BASH_VERSION" >&2
  exit 0
fi
shopt -s extglob dotglob nullglob

[[ -n ${HERDR_PLUGIN_EVENT_JSON:-} ]] || exit 0
command -v jq >/dev/null || exit 0

IFS=$'\t' read -r wt main < <(
  jq -r '[ first(.. | objects | .path?      // empty) // "",
           first(.. | objects | .repo_root? // empty) // "" ] | @tsv' \
    <<<"$HERDR_PLUGIN_EVENT_JSON"
)

[[ -d ${wt:-} && -d ${main:-} && $wt != "$main" ]] || exit 0

# The global list, then this repo's own additions. Both are optional, and the
# lists add up rather than replace.
for list in "${HERDR_PLUGIN_ROOT:-$(dirname "${BASH_SOURCE[0]}")}/links.conf" "$main/.herdr-links"; do
  [[ -f $list ]] || continue

  mapfile -t lines < "$list"
  for line in "${lines[@]}"; do
    path=${line%%#*}
    path=${path##*([[:space:]])}
    path=${path%%*([[:space:]])}
    [[ -n $path ]] || continue

    [[ $path != /* && $path != *..* ]] || continue

    # A trailing slash links the entries inside the directory, not the directory
    # itself. Use it when the repo commits some files into that directory: git
    # creates the directory in the worktree, so a link of the directory is skipped.
    if [[ $path == */ ]]; then
      dir=${path%/}
      [[ -d $main/$dir ]] || continue
      mkdir -p "$wt/$dir"
      for entry in "$main/$dir"/*; do
        [[ ! -e $wt/$dir/${entry##*/} ]] || continue
        ln -s "$entry" "$wt/$dir/${entry##*/}"
      done
      continue
    fi

    [[ -e $main/$path ]] || continue
    [[ ! -e $wt/$path ]] || continue                # never overwrite

    [[ $path != */* ]] || mkdir -p "$wt/${path%/*}"
    ln -s "$main/$path" "$wt/$path"
  done
done

exit 0
