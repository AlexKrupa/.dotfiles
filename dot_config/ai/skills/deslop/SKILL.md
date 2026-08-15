---
name: deslop
argument-hint: "[reply|<path>...]"
description:
  Use when prose written by an agent must be cleaned up after the fact - docs, code comments,
  docstrings, and commit messages on the current branch that ignore the writing rules (AI slop,
  filler, banned words, marketing diction, wall-of-text comments). Deletes every comment the
  branch touched, then restores only the ones that pass. Also rewrites the assistant's
  own last reply on request. Triggers on "deslop", "deslop that", "deslop your reply", "clean up
  the writing", "fix the wording on this branch". Also a required sub-skill of review-me.
---

# deslop

Applies the writing rules from the instructions to prose an agent already wrote. File edits are
folded into their originating commits via `git absorb`. Commit messages get `amend!` commits.
Nothing is pushed, rebased, or amended - the user applies the fixups themselves.

## Rules source - read, do not recall

Open these at the start of **every** run, before editing anything:

- `~/.claude/CLAUDE.md` - the `## Written communication` section (simple language, banned words,
  formatting).
- `~/.claude/rules/code.md` - the `## Comments (inline and doc)` section. These are the rules the
  comment pass applies.
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
| Reflowing to 100 chars, heading case, list structure | Merging or deleting a whole doc |

Ask as **one** grouped prompt at the end, per item, never one prompt per finding. Reply mode never
asks - see below.

Comments do not use this table. They get their own pass, which never asks.

## Comments: delete first, justify back

Reviewing a comment where it sits defends it. Delete it first, then restore only what passes the
test below. Two passes, in order, never merged.

**Pass 1 - delete every one.** In the target files, delete every comment and docstring the branch
added or changed. All of them. No judgment, no exceptions, no reading them first. Code lines stay
untouched. Stage nothing - the deletions sit in the working tree, which is how pass 2 reads them
back.

**Pass 2 - one at a time.** Run `git diff -U8 -- <file>...` to list each deleted comment with the
code around it. Take them in diff order, one per step. For each, answer these questions in order
and stop at the first that decides:

1. **Is it useful?** Does it look unrelated to the code it sits on? Can a reader infer it from that
   code? Either yes -> **stays deleted**. This is the default outcome.
2. **Does it fit in one simple sentence?** Yes -> write that sentence. The point restated in one
   line, not the original with words shaved off.
3. **Otherwise:** trim it, then rewrite it to the rule files - why not what, no history, no filler,
   no banned words.

Never run question 2 or 3 on a comment that failed question 1.

A comment passes question 1 only for something the code cannot show: a why, a constraint invisible
at this line, a workaround plus its cause, a contract callers depend on, a link to an issue or spec.
"It explains what the function does" is not a reason - the function does that.

Docstrings the repo requires (public API, a doc linter) skip question 1. Start them at question 2
and cut to one line.

Expected result: most comments stay deleted, and nearly every survivor is one sentence. If most came
back, pass 2 defended instead of judged. Redo it.

Never prompt the user about a comment. Deletion is the default, and every deletion is visible in the
fixups they review before rebasing.

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
5. Run the comment pass above on the code files in scope: delete all touched comments, then justify
   each one back. Both passes, in order.
6. For each message that needs a rewrite, write the full new message (subject, blank line, body) to
   a temp file and run:

   ```
   ~/.claude/skills/deslop/reword-fixup.sh <parent> <sha> <message-file>
   ```

   It builds the `amend!` commit and aborts on an out-of-range sha, a duplicate subject, or a dirty
   index. Do not hand-write `amend!` commits.
7. Fold the file edits into their commits, passing only the files edited this pass:

   ```
   ~/.claude/skills/review-me/absorb-fixes.sh <parent> <file>...
   ```

   Handle its `needs-message` files as `review-me` does: one conventional-commit one-liner each,
   `git commit -m "<msg>" -- <file>`.
8. If the repo lints prose (markdownlint, vale, a formatter with a comment width), run it on the
   touched files. If there is none, say so - do not invent a command.

## Summary (git modes)

- Files deslopped: count + one line each
- Comments: N deleted, N kept as one sentence, N kept longer
- Commit messages reworded: count + `<sha-short> <old subject>` -> `<new subject>`
- Deferred (would drop information): count + one line each
- Fixups: N via `git absorb`, N via blame, N new commits
- Next step: `git rebase -i --autosquash <parent>`

## Red flags - stop

- Rewriting from memory of the rules instead of the files. That is the defect being fixed.
- Judging comments where they sit instead of deleting them first. Pass 1 has no exceptions.
- Restoring a comment because deleting it feels risky. That is not a reason to keep it.
- Touching git in reply mode. There is nothing to commit.
- Any edit outside prose: renamed symbol, changed condition, moved code.
- Deleting a fact to make a sentence shorter. Shorten the sentence instead.
- Editing files outside `<parent>...HEAD` with no path arg.
- Any git write other than the two helper scripts and the `needs-message` commits. No `push`,
  `rebase`, `amend`, `reset`.
