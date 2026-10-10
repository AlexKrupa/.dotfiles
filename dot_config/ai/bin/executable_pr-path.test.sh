#!/usr/bin/env bash
# Checks pr-path.sh with scratch repos. No LLM.
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/pr-path.sh"
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

check() {
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

# Global config enables 1Password commit signing, which fails headless.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null HOME="$tmp/home"
export GIT_AUTHOR_NAME="Test Dev" GIT_AUTHOR_EMAIL=dev@example.com
export GIT_COMMITTER_NAME="Test Dev" GIT_COMMITTER_EMAIL=dev@example.com
mkdir -p "$HOME"

repo="$tmp/Notes-App"
git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m Init
git -C "$repo" switch -q -c Feature/CSV_export

out=$(cd "$repo" && "$script")
prs="$HOME/.ai/notes-app/prs"
check "file path" "file=$prs/feature-csv-export.md" "$(sed -n 1p <<<"$out")"
check "media path" "media=$prs/feature-csv-export" "$(sed -n 2p <<<"$out")"
check "prs dir exists" yes "$([ -d "$prs" ] && echo yes || echo no)"
check "no media dir" no "$([ -e "$prs/feature-csv-export" ] && echo yes || echo no)"

git -C "$repo" switch -q --detach
(cd "$repo" && "$script") >/dev/null 2>"$tmp/err"
check "detached HEAD exits 1" 1 "$?"
check "detached HEAD message" "pr-path.sh: no current branch (detached HEAD)" "$(cat "$tmp/err")"

exit $fail
