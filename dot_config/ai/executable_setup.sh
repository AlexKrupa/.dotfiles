#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$CLAUDE_DIR"

declare -A links=(
  ["$SCRIPT_DIR/AGENTS.md"]="$CLAUDE_DIR/CLAUDE.md"
)

for source in "${!links[@]}"; do
  target="${links[$source]}"
  name="$(basename "$target")"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
    echo "$name: already linked, skipping"
  elif [ -e "$target" ] || [ -L "$target" ]; then
    echo "$name: target already exists, skipping (remove manually to re-link)"
  else
    ln -s "$source" "$target"
    echo "$name: linked"
  fi
done

# Per-skill symlinks (allows other tools to also place skills in $CLAUDE_DIR/skills/)
mkdir -p "$CLAUDE_DIR/skills"

linked=()
already_linked=()
other=0

for skill_dir in "$SCRIPT_DIR/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  skill="$(basename "$skill_dir")"
  target="$CLAUDE_DIR/skills/$skill"

  if [ -L "$target" ] && [ "$(readlink "$target")" = "$skill_dir" ]; then
    already_linked+=("$skill")
  elif [ -e "$target" ] || [ -L "$target" ]; then
    # Not ours - count as other
    other=$((other + 1))
  else
    ln -s "$skill_dir" "$target"
    linked+=("$skill")
  fi
done

# Count remaining entries not from our source
for entry in "$CLAUDE_DIR/skills"/*; do
  [ -e "$entry" ] || [ -L "$entry" ] || continue
  name="$(basename "$entry")"
  source="$SCRIPT_DIR/skills/$name/"
  if [ -L "$entry" ] && [ "$(readlink "$entry")" = "$source" ]; then
    continue
  fi
  # Only count if not already counted during linking loop
  found=0
  for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    if [ "$(basename "$skill_dir")" = "$name" ]; then
      found=1
      break
    fi
  done
  [ "$found" -eq 0 ] && other=$((other + 1))
done

# Print summary
parts=()
for skill in "${linked[@]}"; do
  parts+=("$skill (linked)")
done
for skill in "${already_linked[@]}"; do
  parts+=("$skill (already linked)")
done
if [ ${#parts[@]} -gt 0 ]; then
  IFS=', '; echo "skills: ${parts[*]}"
fi
if [ "$other" -gt 0 ]; then
  echo "skills: $other other skill(s) already in ~/.claude/skills/"
fi
