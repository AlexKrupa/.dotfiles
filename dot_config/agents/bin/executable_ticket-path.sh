#!/usr/bin/env bash
# Usage: ticket-path.sh <title>
# Prints absolute path to the ticket file under ~/.ai/<repo>/tickets/<date>-<title-slug>.md and
# ensures the parent dir exists. The title is English, so the slug needs no transliteration.
set -euo pipefail

title="${1:?ticket title required}"

slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##')"

dir="$HOME/.ai/$("$(dirname "$0")/repo-slug.sh")/tickets"
mkdir -p "$dir"
printf '%s/%s-%s.md\n' "$dir" "$(date +%F)" "$slug"
