#!/usr/bin/env bash
# Usage: ticket-path.sh <title>
# Prints the absolute path of the ticket file, ~/.ai/<repo>/tickets/<date>-<title-slug>.md, and
# creates its parent dir.
# Exit codes: 0 ok, 1 no title.
set -euo pipefail

# pwd -P: ~/.claude/skills/<name> is a symlink to the skill folder.
here=$(cd "$(dirname "$0")" && pwd -P)
bin=$here/../../bin
# shellcheck source=../../bin/git-lib.sh
source "$bin/git-lib.sh"

title="${1:?ticket title required}"

slug="$(slugify "$title")"

dir="$HOME/.ai/$("$bin/repo-slug.sh")/tickets"
mkdir -p "$dir"
printf '%s/%s-%s.md\n' "$dir" "$(date +%F)" "$slug"
