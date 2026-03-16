#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$CLAUDE_DIR"

declare -A links=(
  ["$SCRIPT_DIR/skills"]="$CLAUDE_DIR/skills"
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
