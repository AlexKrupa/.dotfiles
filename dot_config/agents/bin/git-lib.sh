# shellcheck shell=bash
# Shared helpers of the git scripts. Source this file. Writes nothing.

# Literal substitutions, not [..] classes: in a C locale, brackets match single bytes and corrupt
# multibyte characters. Other non-ASCII characters go to the [^a-z0-9] collapse of slugify.
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

# Usage: slugify TEXT. Prints TEXT as lowercase ASCII words with "-" between them.
slugify() {
  printf '%s' "$1" | translit | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -E 's#[^a-z0-9]+#-#g; s#^-+##; s#-+$##'
}

# Usage: worktree_of BRANCH. Prints the path of the worktree that has BRANCH checked out, or
# nothing.
worktree_of() {
  git worktree list --porcelain | awk -v ref="branch refs/heads/$1" '
    /^worktree / { path = substr($0, 10) }
    $0 == ref { print path; exit }'
}

# Usage: in_range PARENT SHA. True if SHA is in PARENT..HEAD.
in_range() {
  [ "$2" != "$1" ] \
    && git merge-base --is-ancestor "$1" "$2" 2>/dev/null \
    && git merge-base --is-ancestor "$2" HEAD 2>/dev/null
}
