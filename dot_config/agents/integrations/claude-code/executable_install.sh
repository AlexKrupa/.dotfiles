#!/usr/bin/env bash
# Usage: integrations/claude-code/install.sh
# Links CLAUDE.md of this folder to ~/.claude/CLAUDE.md and the skills/*/ of the core into
# ~/.claude/skills/. Installs the plugins that ~/.claude/settings.json enables, from the
# marketplaces that it declares. Prints the status of each entry (see README.md, section Sync). If
# claude is not on PATH, prints a skip line and does nothing.
# Exit codes: 0 ok or skipped, 1 error or a failed plugin install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
core="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if ! command -v claude >/dev/null; then
  echo "claude-code: claude not on PATH, skipped"
  exit 0
fi

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

source="$SCRIPT_DIR/CLAUDE.md"
target="$CLAUDE_DIR/CLAUDE.md"

if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
  add_entry "CLAUDE.md" "linked" "$(tilde_path "$source")"
elif [ -L "$target" ] && [[ "$(readlink "$target")" == "$core/"* ]]; then
  ln -sfn "$source" "$target"
  add_entry "CLAUDE.md" "relinked" "$(tilde_path "$source")"
elif [ -e "$target" ] || [ -L "$target" ]; then
  add_entry "CLAUDE.md" "local"
else
  ln -s "$source" "$target"
  add_entry "CLAUDE.md" "NEW" "$(tilde_path "$source")"
fi

link_entries() {
  local label="$1" glob="$2"
  local target_dir="$CLAUDE_DIR/$label"
  mkdir -p "$target_dir"

  declare -A seen=()

  for src in $core/$glob; do
    [ -e "$src" ] || continue
    local base="$(basename "$src")"
    [ "$base" = "deprecated" ] && continue
    local target="$target_dir/$base"
    seen["$base"]=1

    if [ -L "$target" ] && [ "$(readlink "$target")" = "$src" ]; then
      add_entry "$label/$base" "linked" "$(tilde_path "$src")"
    elif [ -e "$target" ] || [ -L "$target" ]; then
      add_entry "$label/$base" "local"
    else
      ln -s "$src" "$target"
      add_entry "$label/$base" "NEW" "$(tilde_path "$src")"
    fi
  done

  for entry in "$target_dir"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    local base="$(basename "$entry")"
    [ -n "${seen[$base]+x}" ] && continue

    if [ -L "$entry" ]; then
      local link_target="$(readlink "$entry")"
      # A link into the core with no source entry is a stale managed link.
      if [[ "$link_target" == "$core/$label/"* ]]; then
        rm "$entry"
        add_entry "$label/$base" "removed" "$(tilde_path "$link_target") (was stale)"
      else
        add_entry "$label/$base" "local"
      fi
    else
      add_entry "$label/$base" "local"
    fi
  done
}

unlink_deprecated() {
  local label="$1" glob="$2"
  local target_dir="$CLAUDE_DIR/$label"
  for src in $core/$glob; do
    [ -e "$src" ] || continue
    local base="$(basename "$src")"
    local target="$target_dir/$base"
    [ -L "$target" ] || continue
    local link_target="$(readlink "$target")"
    if [[ "$link_target" == "$core/$label/"* ]]; then
      rm "$target"
      add_entry "$label/$base" "removed" "deprecated"
    fi
  done
}

unlink_deprecated skills "skills/deprecated/*/"
link_entries      skills "skills/*/"

failed=0
settings="$CLAUDE_DIR/settings.json"
if [ -f "$settings" ]; then
  while IFS=$'\t' read -r name source; do
    claude plugin marketplace add "$source" --scope user >/dev/null && continue
    add_entry "marketplaces/$name" "FAILED" "$source"
    failed=1
  done < <(jq -r '.extraKnownMarketplaces // {} | to_entries[]
    | [.key, (.value.source | .repo // .path // .url)] | @tsv' "$settings")

  installed="$(claude plugin list --json | jq -r '.[] | select(.scope == "user") | .id')"
  for plugin in $(jq -r '.enabledPlugins // {} | to_entries[] | select(.value) | .key' "$settings"); do
    if grep -qxF "$plugin" <<< "$installed"; then
      add_entry "plugins/$plugin" "installed"
    elif claude plugin install "$plugin" --scope user >/dev/null; then
      add_entry "plugins/$plugin" "NEW"
    else
      add_entry "plugins/$plugin" "FAILED"
      failed=1
    fi
  done
fi

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

exit "$failed"
