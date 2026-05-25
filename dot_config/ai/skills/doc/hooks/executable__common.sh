#!/usr/bin/env bash
# Shared init for design-doc hooks.
# Source this, then call `init_hook` early. On success exports $doc and $docs_dir.
# On any miss it exits the parent silently with code 0.

init_hook() {
  set -e
  cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
  local hook_dir
  hook_dir=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)
  docs_dir=$(bash "$hook_dir/../bin/docs-dir.sh" 2>/dev/null) || exit 0
  doc=$(bash "$hook_dir/../bin/find-active-doc.sh" 2>/dev/null) || exit 0
  [ -n "$doc" ] || exit 0
  export doc docs_dir
}

# Extract leading YYYY-MM-DD from a frontmatter field value.
# Usage: fm_date <file> <field-name>
fm_date() {
  awk -v field="^$2:" '
    $0 ~ field {
      if (match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
        print substr($0, RSTART, RLENGTH)
      }
      exit
    }
  ' "$1"
}
