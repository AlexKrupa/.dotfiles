#!/usr/bin/env bash
# Usage: report-path.sh <parent-ref> [prefix]
# Prints absolute path to the review report file under
# ~/.ai/<repo>/reviews/[<prefix>-]<author>-<branch>.md and ensures the parent dir exists.
set -euo pipefail

parent="${1:?parent ref required}"
prefix="${2:-}"

# Transliterate common Latin-script diacritics to ASCII base letters (both cases -> lowercase).
# Literal substitutions only (no [..] classes) so this is locale-independent: brackets match single
# bytes in a C locale and corrupt multibyte sequences. Unmapped non-ASCII falls through to slugify's
# [^a-z0-9] collapse, same as before.
translit() {
  sed '
    s/à/a/g;s/á/a/g;s/â/a/g;s/ã/a/g;s/ä/a/g;s/å/a/g;s/ā/a/g;s/ă/a/g;s/ą/a/g
    s/ç/c/g;s/ć/c/g;s/č/c/g
    s/ð/d/g;s/đ/d/g;s/ď/d/g
    s/è/e/g;s/é/e/g;s/ê/e/g;s/ë/e/g;s/ē/e/g;s/ė/e/g;s/ę/e/g;s/ě/e/g
    s/ì/i/g;s/í/i/g;s/î/i/g;s/ï/i/g;s/ī/i/g;s/į/i/g;s/ı/i/g
    s/ł/l/g;s/ľ/l/g
    s/ñ/n/g;s/ń/n/g;s/ň/n/g
    s/ò/o/g;s/ó/o/g;s/ô/o/g;s/õ/o/g;s/ö/o/g;s/ø/o/g;s/ō/o/g;s/ő/o/g
    s/ř/r/g
    s/ś/s/g;s/š/s/g;s/ş/s/g
    s/ť/t/g;s/ţ/t/g
    s/ù/u/g;s/ú/u/g;s/û/u/g;s/ü/u/g;s/ū/u/g;s/ů/u/g;s/ű/u/g
    s/ý/y/g;s/ÿ/y/g
    s/ź/z/g;s/ż/z/g;s/ž/z/g
    s/æ/ae/g;s/œ/oe/g;s/ß/ss/g;s/þ/th/g
    s/À/a/g;s/Á/a/g;s/Â/a/g;s/Ã/a/g;s/Ä/a/g;s/Å/a/g;s/Ą/a/g
    s/Ç/c/g;s/Ć/c/g
    s/Ð/d/g;s/Đ/d/g
    s/È/e/g;s/É/e/g;s/Ê/e/g;s/Ë/e/g;s/Ę/e/g
    s/Ì/i/g;s/Í/i/g;s/Î/i/g;s/Ï/i/g
    s/Ł/l/g
    s/Ñ/n/g;s/Ń/n/g
    s/Ò/o/g;s/Ó/o/g;s/Ô/o/g;s/Õ/o/g;s/Ö/o/g;s/Ø/o/g
    s/Ś/s/g;s/Š/s/g
    s/Ù/u/g;s/Ú/u/g;s/Û/u/g;s/Ü/u/g
    s/Ý/y/g
    s/Ź/z/g;s/Ż/z/g;s/Ž/z/g
    s/Æ/ae/g;s/Œ/oe/g;s/Þ/th/g
  '
}

slugify() {
  printf '%s' "$1" | translit | tr '[:upper:]' '[:lower:]' \
    | sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
}

# --git-common-dir with absolute path resolves to the main repo's .git even
# inside a linked worktree, so all worktrees of one repo share one directory.
common_git="$(git rev-parse --path-format=absolute --git-common-dir)"
repo_root="$(cd "$common_git/.." && pwd)"
repo_slug="$(slugify "$(basename "$repo_root")")"

branch="$(git rev-parse --abbrev-ref HEAD)"
branch_slug="$(slugify "${branch//\//-}")"

author="$(git shortlog -sn "$parent..HEAD" | head -1 | sed -E 's/^ *[0-9]+\t//')"
author_slug="$(slugify "$author")"

dir="$HOME/.ai/$repo_slug/reviews"
mkdir -p "$dir"
if [ -n "$prefix" ]; then
  printf '%s/%s-%s-%s.md\n' "$dir" "$(slugify "$prefix")" "$author_slug" "$branch_slug"
else
  printf '%s/%s-%s.md\n' "$dir" "$author_slug" "$branch_slug"
fi
