#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$CLAUDE_DIR"

# Collect entries as "path|status|target" lines, print aligned at the end.
entries=()

add_entry() {
  local path="$1" status="$2" target="${3-}"
  entries+=("$path|$status|$target")
}

tilde_path() {
  local home="$HOME"
  echo "${1/$home/\~}"
}

# --- CLAUDE.md ---

source="$SCRIPT_DIR/AGENTS.md"
target="$CLAUDE_DIR/CLAUDE.md"

if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
  add_entry "CLAUDE.md" "linked" "$(tilde_path "$source")"
elif [ -e "$target" ] || [ -L "$target" ]; then
  add_entry "CLAUDE.md" "local"
else
  ln -s "$source" "$target"
  add_entry "CLAUDE.md" "NEW" "$(tilde_path "$source")"
fi

# --- Link entries from a source dir into a target dir under $CLAUDE_DIR ---

link_entries() {
  local label="$1" glob="$2" strip_ext="${3-}"
  local target_dir="$CLAUDE_DIR/$label"
  mkdir -p "$target_dir"

  # Track which basenames we've already processed
  declare -A seen=()

  # Process source entries
  for src in $SCRIPT_DIR/$glob; do
    [ -e "$src" ] || continue
    local base="$(basename "$src")"
    local display="$base"
    [ -n "$strip_ext" ] && display="$(basename "$src" "$strip_ext")"
    local target="$target_dir/$base"
    seen["$base"]=1

    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
      add_entry "$label/$display" "linked" "$(tilde_path "$src")"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      add_entry "$label/$display" "local"
    else
      ln -s "$src" "$target"
      add_entry "$label/$display" "NEW" "$(tilde_path "$src")"
    fi
  done

  # Scan target dir for entries not covered by source
  for entry in "$target_dir"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    local base="$(basename "$entry")"
    [ -n "${seen[$base]+x}" ] && continue
    local display="$base"
    [ -n "$strip_ext" ] && display="$(basename "$entry" "$strip_ext")"

    if [ -L "$entry" ]; then
      local link_target="$(readlink "$entry")"
      # Check if it points into our source dir (stale managed link)
      if [[ "$link_target" == "$SCRIPT_DIR/$label/"* ]]; then
        rm "$entry"
        add_entry "$label/$display" "removed" "$(tilde_path "$link_target") (was stale)"
      else
        add_entry "$label/$display" "local"
      fi
    else
      add_entry "$label/$display" "local"
    fi
  done
}

link_entries rules  "rules/*.md" .md
link_entries skills "skills/*/"

# --- Print aligned output ---

max_path=0
max_status=0
for line in "${entries[@]}"; do
  IFS='|' read -r path status _ <<< "$line"
  (( ${#path} > max_path )) && max_path=${#path}
  (( ${#status} > max_status )) && max_status=${#status}
done

for line in "${entries[@]}"; do
  IFS='|' read -r path status target <<< "$line"
  if [ -n "$target" ]; then
    printf "%-${max_path}s  %-${max_status}s  -> %s\n" "$path" "$status" "$target"
  else
    printf "%-${max_path}s  %-${max_status}s\n" "$path" "$status"
  fi
done
