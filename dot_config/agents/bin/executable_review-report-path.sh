#!/usr/bin/env bash
# Usage: review-report-path.sh <parent-ref | log-range> [prefix]
# Prints absolute path to the review report file under
# ~/.ai/<repo>/reviews/<date>-[<prefix>-]<branch>-<author>.md and ensures the parent dir exists.
# The author is the majority author of the range (<parent-ref>..HEAD), or the current user when
# the range has no commits.
set -euo pipefail

range="${1:?parent ref or log range required}"
[[ "$range" == *..* ]] || range="$range..HEAD"
prefix="${2:-}"

# Transliterate common Latin-script diacritics to ASCII base letters (both cases -> lowercase).
# Literal substitutions only (no [..] classes), for locale independence: brackets match single
# bytes in a C locale and corrupt multibyte sequences. Unmapped non-ASCII falls through to slugify's
# [^a-z0-9] collapse.
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

repo_slug="$("$(dirname "$0")/repo-slug.sh")"

branch="$(git rev-parse --abbrev-ref HEAD)"
branch_slug="$(slugify "${branch//\//-}")"

author="$(git shortlog -sn "$range" | head -1 | sed -E 's/^ *[0-9]+\t//')"
[ -n "$author" ] || author="$(git var GIT_AUTHOR_IDENT | sed 's/ <.*//')"
author_slug="$(slugify "$author")"

date_prefix="$(date +%F)"

dir="$HOME/.ai/$repo_slug/reviews"
mkdir -p "$dir"
if [ -n "$prefix" ]; then
  printf '%s/%s-%s-%s-%s.md\n' "$dir" "$date_prefix" "$(slugify "$prefix")" "$branch_slug" "$author_slug"
else
  printf '%s/%s-%s-%s.md\n' "$dir" "$date_prefix" "$branch_slug" "$author_slug"
fi
