# Commit history rules

Shared by `review-me` and `draft-pr`. The rules find the branch commits that must be squashed into
an earlier branch commit. Each skill decides how it confirms and reports the squashes. Both rewrite
history only with `~/.config/ai/bin/git-squash-fixups.sh`.

Goal: each commit on the branch has value by itself. Find only commits that must be squashed.

## Input

```
git log --reverse --format='%h %s' <parent>..HEAD
git log --reverse --name-only --format='--- %h %s' <parent>..HEAD
```

## Flag a commit if one of these is true

- **Repair subject** - the subject or the body tells that it repairs an earlier branch commit:
  "fix typo", "address review", "oops", "forgot", "adjust X", "revert of <earlier commit>".
- **Placeholder subject** - `wip`, `tmp`, `fix`, `stash`, `.`, or a subject that names no
  capability.
- **Repair content** - the commit changes only lines that an earlier branch commit added, and adds
  no capability that a reader can name.

Find the target: the earlier branch commit that added the lines that this commit changes. Use
`git blame` if the subject does not name it. If there is no target in the range, there is no
finding.

## Never flag

- A commit that has value by itself, also a small one.
- Merge commits, and all commits at or below `<parent>`.
- `fixup!` and `amend!` commits. `--autosquash` already puts them in the correct position.
- A commit that is too large or has more than one concern. These rules do not split commits.
