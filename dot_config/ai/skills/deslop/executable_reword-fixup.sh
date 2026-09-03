#!/usr/bin/env bash
# Usage: reword-fixup.sh <parent> <sha> <message-file>
#   <parent>       the ref review-branch resolved (its `parent:` line)
#   <message-file> the full new message: subject, blank line, optional body
#
# Queues the rewrite as an `amend!` commit for `git rebase -i --autosquash <parent>` to apply.
#
# `git commit --fixup=reword:<sha>` cannot take -m/-F (git 2.55). The `amend!` commit is built by
# hand: first line `amend! <original subject>`, blank line, then the new message.
set -euo pipefail

die() { printf '%s\n' "$1" >&2; exit 1; }

[ "$#" -eq 3 ] || die "Usage: reword-fixup.sh <parent> <sha> <message-file>"
parent="$1"; target="$2"; msgfile="$3"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git work tree."
[ -s "$msgfile" ] || die "Message file missing or empty: $msgfile"
parent_sha="$(git rev-parse --verify --quiet "$parent")" || die "Parent ref '$parent' not found."
target_sha="$(git rev-parse --verify --quiet "${target}^{commit}")" \
  || die "Commit '$target' not found."

[ "$target_sha" != "$parent_sha" ] || die "Refusing to reword the parent commit."
git merge-base --is-ancestor "$parent_sha" "$target_sha" 2>/dev/null \
  && git merge-base --is-ancestor "$target_sha" HEAD 2>/dev/null \
  || die "Commit $target_sha is outside $parent..HEAD."

# An amend! commit matches by subject text - a duplicate subject rewords the wrong commit.
subject="$(git log -1 --format=%s "$target_sha")"
matches="$(git log --format=%s "$parent_sha"..HEAD | grep -Fxc -- "$subject" || true)"
[ "$matches" -eq 1 ] \
  || die "Subject '$subject' appears $matches times in $parent..HEAD - cannot target it."

# --allow-empty commits whatever is staged - a dirty index would go into this commit.
[ -z "$(git diff --cached --name-only)" ] || die "Index not empty - commit or reset it first."

# Command substitution strips trailing newlines on both sides - this compares message bodies.
[ "$(cat "$msgfile")" != "$(git log -1 --format=%B "$target_sha")" ] \
  || die "New message is identical to the current one - nothing to reword."

{ printf 'amend! %s\n\n' "$subject"; cat "$msgfile"; } | git commit -q --allow-empty -F -

printf 'reword-fixup: %s %s\n' "$(git rev-parse --short "$target_sha")" "$(head -1 "$msgfile")"
