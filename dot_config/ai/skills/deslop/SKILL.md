---
name: deslop
argument-hint: "[reply|<path>...]"
description:
  Use when prose written by an agent must be cleaned up after the fact - docs, code comments,
  docstrings, and commit messages on the current branch that ignore the writing rules (AI slop,
  filler, banned words, marketing diction, wall-of-text comments). Also rewrites the assistant's
  own last reply on request. Triggers on "deslop", "deslop that", "deslop your reply", "clean up
  the writing", "fix the wording on this branch". Also a required sub-skill of review-me.
---

# deslop

Applies the writing rules that are already in the instructions to prose an agent already wrote. File
edits are folded into their originating commits via `git absorb`; commit messages get `amend!`
commits. Nothing is pushed, rebased, or amended - the user applies the fixups themselves.

## Rules source - read, do not recall

Open these at the start of **every** run, before editing anything:

- `~/.claude/CLAUDE.md` - the `## Communication` section (simple language, banned words,
  formatting).
- `~/.claude/rules/documenting.md` - for Markdown and docs.
- The repo's own style docs, if any (`CONTRIBUTING*`, `docs/style*`). They win over the personal
  rules for files in that repo.

This skill defines no writing rules of its own. Recalling the rules instead of reading them is the
failure this skill exists to fix. If `~/.claude/CLAUDE.md` is missing, say so and stop.

## Modes

| Invocation | Target | Git |
| ---------- | ------ | --- |
| `/deslop reply` | The last assistant message, or text pasted with it | no |
| `/deslop` | The branch diff (`<parent>...HEAD`) + its commit messages | yes |
| `/deslop docs/ README.md` | Those paths, whole file, no commit-message pass | yes |

No args outside a git repo falls back to reply mode.

Branch mode covers: Markdown and other docs changed by the branch, comments and docstrings changed
by the branch, and commit subjects and bodies in `<parent>..HEAD`.

**Out of scope:** code, identifiers, string literals, tests, generated or vendored files, PR/MR
descriptions, and anything outside the diff unless passed as a path arg.

## The one judgment call

Auto-apply any fix that keeps every fact. Ask first only when the fix drops one.

Test: would a reader lose something they cannot get from the surrounding code or doc?

| Auto-apply | Ask first |
| ---------- | --------- |
| Banned words, filler transitions, marketing diction | Deleting a paragraph or section |
| Em-dashes, smart quotes, Markdown links -> plain URLs | Dropping a caveat or version note |
| Same content, shorter sentence | Removing the only example of a thing |
| Cutting a comment that restates the code | Cutting a comment that states a *why* |
| Reflowing to 100 chars, heading case, list structure | Merging or deleting a whole doc |

Ask as **one** grouped prompt at the end, per item, never one prompt per finding. Reply mode never
asks - see below.

## Reply mode

1. Read the rule files above. Same as any other mode - no shortcut because it is "just a reply".
2. Print the rewritten text and nothing else. No diff, no list of what changed, no preamble.
3. Apply every fix, including ones that drop information. Add one line under the rewrite naming what
   was dropped, so the user can put it back. Never prompt.

Skip the git steps entirely - there is no working tree, no `<parent>`, no absorb.

## Branch and path loop

0. **Precondition:** `git status --porcelain` must be empty. If not, show the dirty paths and tell
   the user to commit or stash. Do not auto-stash.
1. Read the rule files above.
2. Resolve the base (skip when path args were given):

   ```
   ~/.claude/skills/review-branch/branch-context.sh
   ```

   Use its `parent:` value as `<parent>`. Do not recompute it.
3. Collect targets: `git diff --name-only <parent>...HEAD` filtered to files holding prose, and
   `git log --format='%H %s%n%b' <parent>..HEAD` for the messages.
4. Edit the prose in place. Prose only - one changed line that alters code means you went too far.
5. For each message that needs a rewrite, write the full new message (subject, blank line, body) to
   a temp file and run:

   ```
   ~/.claude/skills/deslop/reword-fixup.sh <parent> <sha> <message-file>
   ```

   It builds the `amend!` commit and aborts on an out-of-range sha, a duplicate subject, or a dirty
   index. Do not hand-write `amend!` commits.
6. Fold the file edits into their commits, passing only the files edited this pass:

   ```
   ~/.claude/skills/review-me/absorb-fixes.sh <parent> <file>...
   ```

   Handle its `needs-message` files as `review-me` does: one conventional-commit one-liner each,
   `git commit -m "<msg>" -- <file>`.
7. If the repo lints prose (markdownlint, vale, a formatter with a comment width), run it on the
   touched files. If there is none, say so - do not invent a command.

## Summary (git modes)

- Files deslopped: count + one line each
- Commit messages reworded: count + `<sha-short> <old subject>` -> `<new subject>`
- Deferred (would drop information): count + one line each
- Fixups: N via `git absorb`, N via blame, N new commits
- Next step: `git rebase -i --autosquash <parent>`

## Red flags - stop

- Rewriting from memory of the rules instead of the files. That is the defect being fixed.
- Touching git in reply mode. There is nothing to commit.
- Any edit outside prose: renamed symbol, changed condition, moved code.
- Deleting a fact to make a sentence shorter. Shorten the sentence instead.
- Editing files outside `<parent>...HEAD` with no path arg.
- Any git write other than the two helper scripts and the `needs-message` commits. No `push`,
  `rebase`, `amend`, `reset`.
