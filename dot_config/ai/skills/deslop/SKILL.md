---
name: deslop
argument-hint: "[reply|<path>...]"
description:
  Use when an agent wrote prose that ignores the writing rules - docs, code comments, docstrings,
  and commit messages on the current branch that contain AI slop, filler, banned words, marketing
  diction, or very long comments. Deletes each comment that the branch touched, then restores only
  the comments that pass the test. Also rewrites the assistant's last reply on request. Triggers on
  "deslop", "deslop that", "deslop your reply", "clean up the writing", "fix the wording on this
  branch". Also a required sub-skill of review-me.
---

# deslop

This skill applies the writing rules from the instructions to prose that an agent wrote.
`git absorb` folds the file edits into their originating commits. Commit messages get `amend!`
commits. This skill does not push, rebase, or amend. The user applies the fixups.

## Rules source - read, do not recall

Open these files at the start of **every** run, before you edit anything:

- `~/.claude/CLAUDE.md` - the `## Written communication` section. It has the simple language,
  banned words, and formatting rules.
- `~/.claude/rules/code.md` - the `## Comments (inline and doc)` section. The comment pass applies
  these rules.
- `~/.claude/rules/documenting.md` - for Markdown and docs.
- The repo's own style docs, if they exist (`CONTRIBUTING*`, `docs/style*`). For files in that repo,
  these docs have priority over the personal rules.

This skill defines no writing rules. Do not recall them - recall causes the defect that this skill
must correct. If `~/.claude/CLAUDE.md` is missing, tell the user and stop.

## Modes

| Invocation                | Target                                                      | Git |
| ------------------------- | ----------------------------------------------------------- | --- |
| `/deslop reply`           | The last assistant message, or text that the user pasted    | no  |
| `/deslop`                 | The branch diff (`<parent>...HEAD`) and its commit messages | yes |
| `/deslop docs/ README.md` | Those paths, the full file, no commit-message pass          | yes |

If there are no args and the directory is not a git repo, use reply mode.

Branch mode includes:

- Markdown and other docs that the branch changed
- Comments and docstrings that the branch changed
- Commit subjects and bodies in `<parent>..HEAD`

**Out of scope:** code, identifiers, string literals, tests, generated files, vendored files, PR
descriptions, and MR descriptions. Also all files outside the diff, unless the user gives them as a
path arg.

## Judgment call

Apply each fix that keeps all the facts. Ask first only if the fix removes a fact.

Test: does the reader lose data that the adjacent code or doc does not show?

| Apply immediately                                     | Ask first                              |
| ----------------------------------------------------- | -------------------------------------- |
| Banned words, filler transitions, marketing diction   | Deletion of a paragraph or a section   |
| Em-dashes, smart quotes, Markdown links -> plain URLs | Removal of a caveat or a version note  |
| Same content, shorter sentence                        | Removal of the only example of a thing |
| Reflow to 100 chars, heading case, list structure     | Merge or deletion of a full doc        |

Ask with **one** grouped prompt at the end. Put one item in it for each finding. Do not use one
prompt per finding. Reply mode never asks.

When you update prose, replace the obsolete text with accurate text. Do not keep the obsolete text
and add a correction. The final document must read as if it was correct from the start.

Comments do not use this table. The comment pass applies to them. That pass never asks.

## Comments: delete first, then justify

If you examine a comment in place, you will defend it. Delete the comment first. Then restore it
only if it passes the test below. Do the two passes in this sequence. Never merge them.

**Pass 1 - delete all of them.** In the target files, delete each comment and docstring that the
branch added or changed. Delete all of them. Use no judgment. Make no exceptions. Do not read them
first. Do not change the code lines. Stage nothing. The deletions stay in the working tree. Pass 2
reads them there.

**Pass 2 - one comment at a time.** Run `git diff -U8 -- <file>...` to show each deleted comment
with the adjacent code. Process them in diff order, one comment per step. For each comment, answer
these questions in sequence. Stop at the first question that gives a decision.

1. **Is it useful?** Does it look unrelated to the code at that location? Can a reader infer it from
   that code? If the answer to one of these questions is yes, the comment **stays deleted**. This is
   the default result.
2. **Does it fit in one simple sentence?** If yes, write that sentence. Write the point again in one
   line. Do not write the original with fewer words.
3. **If not:** cut the comment, then write it again to the rule files. Give the why, not the what.
   Include no history, no filler, and no banned words.

Never run question 2 or question 3 on a comment that failed question 1.

A comment passes question 1 only for data that the code cannot show:

- a why
- a constraint that is not visible at this line
- a workaround with its cause
- a contract that callers use
- a link to an issue or a spec

"It explains what the function does" is not a sufficient reason. The function shows that.

Docstrings that the repo makes necessary (public API, a doc linter) do not use question 1. Start
them at question 2 and reduce them to one line.

Expected result: most comments stay deleted. Almost all of the comments that stay are one sentence.
If most of the comments returned, pass 2 defended them instead of judged them. Do pass 2 again.

Never prompt the user about a comment. Deletion is the default. The user sees each deletion in the
fixups before the rebase.

## Reply mode

1. Read the rule files above. Do this for each mode. Do not skip it because the target is only a
   reply.
2. Print the new text and nothing more. No diff, no list of changes, no preamble.
3. Apply each fix, including the fixes that remove data. Add one line below the new text. It names
   the removed data for the user to restore. Never prompt.

Skip all the git steps. There is no working tree, no `<parent>`, and no absorb.

## Branch and path loop

0. **Precondition:** `git status --porcelain` must give no output. If it gives output, show the
   dirty paths to the user. Tell the user to commit or stash. Do not stash automatically.
1. Read the rule files above.
2. Find the base. Skip this step if the user gave path args.

   ```
   ~/.claude/skills/review-branch/branch-context.sh
   ```

   Use its `parent:` value as `<parent>`. Do not calculate it again.

3. Collect the targets. Use `git diff --name-only <parent>...HEAD`, filtered to the files that hold
   prose. Use `git log --format='%H %s%n%b' <parent>..HEAD` for the messages.
4. Edit the prose in place. Edit prose only. If you change one code line, you went too far.
5. Run the comment pass on the code files in scope. Delete all touched comments, then justify each
   comment again. Do both passes, in sequence.
6. For each message that needs a rewrite, write the full new message (subject, empty line, body) to
   a temp file. Then run:

   ```
   ~/.claude/skills/deslop/reword-fixup.sh <parent> <sha> <message-file>
   ```

   The script builds the `amend!` commit. It stops on an out-of-range sha, a duplicate subject, or a
   dirty index. Do not write `amend!` commits manually.

7. Fold the file edits into their commits. Give only the files that you edited in this pass:

   ```
   ~/.claude/skills/review-me/absorb-fixes.sh <parent> <file>...
   ```

   Process its `needs-message` files as `review-me` does. Write one conventional-commit line for
   each file. Then run `git commit -m "<msg>" -- <file>`.

8. If the repo lints prose, run the linter on the touched files. Examples: markdownlint, vale, a
   formatter with a comment width. If the repo has no linter, tell the user. Do not invent a
   command.

## Summary (git modes)

- Files changed: count and one line for each
- Comments: N deleted, N kept as one sentence, N kept longer
- Commit messages reworded: count and `<sha-short> <old subject>` -> `<new subject>`
- Deferred (the fix would remove data): count and one line for each
- Fixups: N by `git absorb`, N by blame, N as new commits
- Next step: `git rebase -i --autosquash <parent>`

## Mistakes - stop

- You write from memory of the rules instead of from the files. This is the defect to correct.
- You judge comments in place instead of deleting them first. Pass 1 has no exceptions.
- You restore a comment because deletion feels risky. This is not a sufficient reason.
- You use git in reply mode. There is nothing to commit.
- You make an edit outside prose: a renamed symbol, a changed condition, moved code.
- You delete a fact to make a sentence shorter. Make the sentence shorter instead.
- You edit files outside `<parent>...HEAD` with no path arg.
- You do a git write that is not one of the two helper scripts and not a `needs-message` commit. No
  `push`, `rebase`, `amend`, `reset`.
