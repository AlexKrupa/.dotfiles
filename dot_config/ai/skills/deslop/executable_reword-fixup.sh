#!/usr/bin/env bash
# Usage: reword-fixup.sh <parent> <sha> <message-file>
# Queues a commit-message rewrite as an `amend!` commit, so the user applies it later with
# `git rebase -i --autosquash <parent>`. Same deal as git-absorb's fixups: nothing is rewritten now.
#
# <parent>       the parent ref/SHA review-branch resolved (its `parent:` line).
# <sha>          the commit to reword; must be inside <parent>..HEAD.
# <message-file> the full new message (subject line, blank line, optional body).
#
# `git commit --fixup=reword:<sha>` cannot take -m/-F (git 2.55), so the `amend!` commit is built by
# hand: first line `amend! <original subject>`, blank line, then the new message. Autosquash matches
# it by that subject, so it aborts when the subject is not unique in <parent>..HEAD.
#
# Makes exactly one git write: an empty commit on HEAD. No push/rebase/amend/reset.
set -euo pipefail

die() { printf '%s\n' "$1" >&2; exit 1; }

[ "$#" -eq 3 ] || die "Usage: reword-fixup.sh <parent> <sha> <message-file>"
parent="$1"; target="$2"; msgfile="$3"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git work tree."
[ -s "$msgfile" ] || die "Message file missing or empty: $msgfile"
parent_sha="$(git rev-parse --verify --quiet "$parent")" || die "Parent ref '$parent' not found."
target_sha="$(git rev-parse --verify --quiet "${target}^{commit}")" \
  || die "Commit '$target' not found."

# In range: descendant of parent, ancestor of HEAD, not parent itself.
[ "$target_sha" != "$parent_sha" ] || die "Refusing to reword the parent commit."
git merge-base --is-ancestor "$parent_sha" "$target_sha" 2>/dev/null \
  && git merge-base --is-ancestor "$target_sha" HEAD 2>/dev/null \
  || die "Commit $target_sha is outside $parent..HEAD."

# An amend! commit is matched by subject text, so a duplicate subject would reword the wrong commit.
subject="$(git log -1 --format=%s "$target_sha")"
matches="$(git log --format=%s "$parent_sha"..HEAD | grep -Fxc -- "$subject" || true)"
[ "$matches" -eq 1 ] \
  || die "Subject '$subject' appears $matches times in $parent..HEAD - cannot target it."

# --allow-empty commits whatever is staged, so a dirty index would be swallowed by this commit.
[ -z "$(git diff --cached --name-only)" ] || die "Index not empty - commit or reset it first."

# Command substitution strips trailing newlines on both sides, so this compares message bodies.
[ "$(cat "$msgfile")" != "$(git log -1 --format=%B "$target_sha")" ] \
  || die "New message is identical to the current one - nothing to reword."

{ printf 'amend! %s\n\n' "$subject"; cat "$msgfile"; } | git commit -q --allow-empty -F -

printf 'reword-fixup: %s %s\n' "$(git rev-parse --short "$target_sha")" "$(head -1 "$msgfile")"
