---
name: deslop
argument-hint: "[reply | uncommitted | staged | <path>... | <free-text target>]"
description:
  Use when an agent wrote prose that ignores the writing rules - docs, code comments, docstrings,
  and commit messages on the current branch, in uncommitted or staged changes, or in a part of the
  code that the user names, that contain AI slop, filler, banned words, marketing diction, or very
  long comments. Also use when the user asks to fix the wording of the assistant's last reply.
  Triggers on "deslop", "deslop that", "deslop your reply", "deslop my uncommitted changes",
  "deslop the README intro", "clean up the writing", "fix the wording on this branch".
---

# deslop

This skill applies the writing rules from the instructions to prose that an agent wrote. In branch
and path mode, `git absorb` folds the file edits into their originating commits, and commit
messages get `amend!` commits. The user applies the fixups. In the working-tree modes, the edits
stay in the working tree. This skill does not push, rebase, or amend.

## Rules source - read, do not recall

Open these files at the start of **every** run, before you edit anything. Read them with the Read
tool, not with Bash:

- `~/.config/ai/AGENTS.md` - the `## Written communication` section. It has the simple language,
  banned words, and formatting rules.
- `~/.config/ai/rules/code.md` - the `## Comments (inline and doc)` section. The comment pass
  applies these rules.
- `~/.config/ai/rules/documenting.md` - for Markdown and docs.
- The repo's own style docs, if they exist (`CONTRIBUTING*`, `docs/style*`). For files in that repo,
  these docs have priority over the personal rules.

This skill defines no writing rules. Do not recall them - recall causes the defect that this skill
must correct. The files are in your context, but in a long session they are far from the task.
Read them again. If `~/.config/ai/AGENTS.md` is missing, tell the user and stop.

## Modes

Select the mode from the user's words. The user does not need a keyword. If the words fit more than
one mode, ask before you edit.

| Mode               | The user says                                   | Base       | Output       |
| ------------------ | ----------------------------------------------- | ---------- | ------------ |
| reply              | "reply", "your reply", or pasted text           | -          | Reply        |
| branch             | nothing                                         | `<parent>` | Fixups       |
| path               | only paths                                      | `<parent>` | Fixups       |
| uncommitted        | "uncommitted", "working tree", "my changes"     | `HEAD`     | Working tree |
| staged             | "staged", "index"                               | `HEAD`     | Working tree |
| branch-uncommitted | uncommitted, plus "with the branch"             | `<parent>` | Working tree |
| branch-staged      | staged, plus "with the branch"                  | `<parent>` | Working tree |
| target             | other words that name text in the repo          | `<parent>` | Working tree |

Targets:

- reply: the last assistant message, or the pasted text.
- branch: the branch diff `<parent>...HEAD` and its commit messages.
- path: the full files at those paths. There is no commit-message pass.
- uncommitted: the working tree and the untracked files vs `HEAD`. The branch commits are not in
  scope.
- staged: the index vs `HEAD`. The branch commits are not in scope.
- branch-uncommitted and branch-staged: the branch commits plus the uncommitted or staged changes.
- target: the text that the words name, for example a doc section, the comments in a file, or the
  docstrings of a class.

The base is the point that tells which comments the target added (see the comment pass). The
working-tree modes are uncommitted, staged, the two branch- modes, and target.

If there are no args and the directory is not a git repo, use reply mode. If the words name text in
the conversation and not in a file, use reply mode.

The diff modes (branch, uncommitted, staged, and the branch- modes) include:

- Markdown and other docs that the diff changed
- Comments and docstrings that the diff changed
- Commit subjects and bodies in `<parent>..HEAD` - branch mode only

**Out of scope:** code, identifiers, string literals, tests, generated files, vendored files, PR
descriptions, and MR descriptions. Also all files outside the mode's target.

## Judgment call

Apply each fix that keeps all the facts. Ask first only if the fix removes a fact.

Test: does the reader lose data that the adjacent code or doc does not show?

| Apply immediately                                     | Ask first                              |
| ----------------------------------------------------- | -------------------------------------- |
| Banned words, filler transitions, marketing diction   | Deletion of a paragraph or a section   |
| Em-dashes, smart quotes                               | Removal of a caveat or a version note  |
| Same content, shorter sentence                        | Removal of the only example of a thing |
| Reflow to 100 chars, heading case, list structure     | Merge or deletion of a full doc        |

Keep Markdown links in files. The plain-URL rule is for replies only. In reply mode, change
`[text](url)` to `text (url)`. In the other modes, do not touch links.

Ask with **one** grouped prompt at the end. Put one item in it for each finding. Do not use one
prompt per finding. Reply mode never asks.

When you update prose, replace the obsolete text with accurate text. Do not keep the obsolete text
and add a correction. The final document must read as if it was correct from the start.

Comments do not use this table. The comment pass applies to them. That pass never asks.

## Comments: delete first, then justify

If you examine a comment in place, you will defend it. Delete the comment first. Then restore it
only if it passes the test below. Do the two passes in this sequence. Never merge them.

An added comment does not exist at the base of the mode (see "Modes"). An old comment exists at the
base.

**Pass 1 - delete all of them.** In the target, delete each added comment and docstring. Delete all
of them. Use no judgment. Make no exceptions. Do not read them first. Do not change the code lines.
Stage nothing. The deletions stay in the working tree. Pass 2 reads them there.

Pass 1 does not delete old comments:

- If the diff changed an old comment, pass 2 examines only the changed lines, with the same
  questions. Delete each changed line that fails question 1. Keep the unchanged lines.
- In target mode, pass 2 also examines each old comment in the target that the diff did not
  change. Ask the same questions about the full comment where it is, with no deletion first. If it
  fails question 1, delete it. If it passes question 1 and obeys the rule files, do not change it.

**Pass 2 - one comment at a time.** Show each deleted comment with the adjacent code. In branch and
path mode, run `git diff -U8 -- <file>...`. In the working-tree modes, run
`git diff --no-index -U8 <copy> <file>` for each file, with the copies from step 3 of the
working-tree loop. Process them in diff order, one comment per step. For each comment, answer
these questions in sequence. Stop at the first question that gives a decision.

1. **Is it redundant?** Does it look unrelated to the code at that location? Can a reader infer it
   from that code? If the answer to one of these questions is yes, the comment **stays deleted**.
   This is the default result.
2. **Does it fit in one simple sentence?** If yes, write that sentence. Write the point again in one
   line. Do not write the original with fewer words.
3. **If not:** cut the comment, then write it again as the rule files tell. Give the why, not the
   what. Include no history, no filler, and no banned words.

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

Expected result: you delete most comments. Almost all kept comments are one sentence. If you kept
most comments, pass 2 defended them instead of judging them. Do pass 2 again.

Never prompt the user about a comment. Deletion is the default. The user sees each deletion in the
fixups before the rebase, or in `git diff` in the working-tree modes.

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
2. Find the base. Also do this step with path args - step 7 needs `<parent>`. Path args change
   only the targets.

   ```
   ~/.config/ai/bin/git-diff-context.sh --parent-only
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
   ~/.claude/skills/deslop/git-reword-fixup.sh <parent> <sha> <message-file>
   ```

   The script builds the `amend!` commit. It stops on an out-of-range sha, a duplicate subject, or a
   dirty index. Do not write `amend!` commits manually.

7. Fold the file edits into their commits. Give only the files that you edited in this pass:

   ```
   ~/.config/ai/bin/git-absorb-fixes.sh <parent> <file>...
   ```

   Process its `needs-message` files as `review-me` does. Write one conventional-commit line for
   each file. Then run `git commit -m "<msg>" -- <file>`.

8. If the repo lints prose, run the linter on the touched files. Examples: markdownlint, vale, a
   formatter with a comment width. If the repo has no linter, tell the user. Do not invent a
   command.

## Working-tree loop

Use this loop in the uncommitted, staged, branch-uncommitted, branch-staged, and target modes. The
tree can be dirty. The user's changes stay where they are, in the working tree or in the index.

1. Read the rule files above.
2. Get the scope:

   | Mode               | Command                                                            |
   | ------------------ | ------------------------------------------------------------------ |
   | uncommitted        | `~/.config/ai/bin/git-diff-context.sh --uncommitted`               |
   | staged             | `~/.config/ai/bin/git-diff-context.sh --staged`                    |
   | branch-uncommitted | `~/.config/ai/bin/git-diff-context.sh --uncommitted --with-branch` |
   | branch-staged      | `~/.config/ai/bin/git-diff-context.sh --staged --with-branch`      |
   | target             | `~/.config/ai/bin/git-diff-context.sh`                             |

   Use its `parent:` value as the base and its `diff-command` for the diff. In the uncommitted
   modes, each `??` line in `## Uncommitted` is an untracked file. All of its comments are added.
   In target mode, if the helper stops because the branch has no diff, use `HEAD` as the base. If
   the directory is not a git repo, all comments in the target are old.

3. Collect the targets. In the diff modes, use the `diff-command` with `--name-only`, plus the
   untracked files, filtered to the files that hold prose. In target mode, find the text that the
   user's words name. If the words match no text, or more text than the user can mean, ask before
   you edit. Then copy each target file to a temp dir. Pass 2 of the comment pass diffs against
   these copies.
4. Edit the prose in place. Edit prose only. If you change one code line, you went too far.
5. Run the comment pass on the code files in scope. In target mode, `git diff <base> -- <file>`
   shows the added comments. An untracked file has only added comments.
6. Leave all edits in the working tree. Do not stage, commit, absorb, or reword. In staged mode, the
   edits stay unstaged. The user stages them.
7. If the repo lints prose, run the linter on the touched files, as in step 8 of the branch and
   path loop.

## Summary (git modes)

Print only these lines, in this sequence. Skip the lines that do not apply to the mode. Then print
the grouped prompt, if there are deferred items. Do not add an intro line, quoted comments, or
other lists. The fixups or `git diff` show each edit.

- Files changed: count and one line for each
- Comments: N deleted, N kept as one sentence, N kept longer
- Old comments (target mode): N deleted, N rewritten, N unchanged
- Commit messages reworded (branch mode): count and `<sha-short> <old subject>` -> `<new subject>`
- Deferred (the fix would remove data): count and one line for each
- Fixups (branch and path mode): N by `git absorb`, N by blame, N as new commits
- Linter: the command and its result, or `none in repo`
- Out of scope: only if slop remains outside the targets - the paths, on one line
- Next step: `git rebase -i --autosquash <parent>` in branch and path mode. In the working-tree
  modes: review the edits with `git diff`.

## Mistakes - stop

- You write from memory of the rules instead of from the files. This is the defect to correct.
- You judge comments in place instead of deleting them first. Pass 1 has no exceptions.
- You restore a comment because deletion feels risky. This is not a sufficient reason.
- You use git in reply mode. There is nothing to commit.
- You make an edit outside prose: a renamed symbol, a changed condition, moved code.
- You delete a fact to make a sentence shorter. Make the sentence shorter instead.
- You edit files outside the mode's target.
- In branch and path mode, you do a git write that is not one of the two helper scripts and not a
  `needs-message` commit. No `push`, `rebase`, `amend`, `reset`.
- In the working-tree modes, you do a git write of any kind.
