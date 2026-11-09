#!/usr/bin/env bash
# Usage: montage.sh <folder>
#
# Makes one labeled image for each source file in the output of `android preview render`. Writes
# <folder>/<FileName>Kt.png and prints each path.

set -euo pipefail

folder=${1:?Usage: montage.sh <folder>}
# magick fails with `unable to read font` when it has no explicit font.
font=/System/Library/Fonts/Supplemental/Arial.ttf

find "$folder" -mindepth 2 -type f -name '*.png' | sed 's|/[^/]*$||' | sort -u |
  while read -r previews; do
    target="$folder/$(basename "$previews").png"
    magick montage -font "$font" -label '%t' "$previews"/*.png -tile 2x -geometry '+24+24' \
      -background '#2b2b2b' -fill white -pointsize 28 "$target"
    echo "$target"
  done
