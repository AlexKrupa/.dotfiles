---
name: review-me
description:
  Self-review of the current branch. Applies low-risk fixes and folds them into branch commits. Asks
  before behavior changes or broad refactors.
disable-model-invocation: true
---

# review-me

This skill adds a fix loop to `review-branch`. `review-branch` does the audit and the report. This
skill decides what to do with the findings. It folds the fixes into the commits that they fix, with
`git absorb`. It never pushes. It rewrites history only through `history-rewrite.sh`, after the
user confirms. In auto mode, it also squashes the fixups with no prompt.

## Auto mode

Auto mode is on when the caller tells you to use auto mode, for example the Superpowers branch
finish in `AGENTS.md`. A direct `/review-me` call is standalone mode.

In auto mode, the history pass (step 10) always runs `history-rewrite.sh`, also with no squashes.
The script squashes all `fixup!` and `amend!` commits in `<parent>..HEAD` into their targets. Do not
ask before this rewrite. The repair squashes of "Commit history" still need a confirmation for each
item.

## REQUIRED SUB-SKILLS

- `review-branch` - does the audit and writes the report. Do not do its git discovery, checklist,
  severity scheme, or report yourself. Read the report file before you continue.
- `deslop` - the writing pass on prose, comments, and commit messages (loop step 7). This pass is
  necessary. Do not edit wording or messages yourself. Do not skip it because the diff "has no
  docs". It also examines comments and commit messages.

## Fix policy

### Apply with no prompt

- Typos in string literals. Comments and docs are for `deslop` (step 7).
- Lint and format problems. Use the configured tool of the repo, for example `eslint --fix`,
  `ruff format`, `gofmt`, or `cargo fmt`. Find the tool. Do not edit by hand.
- Unused imports that this branch added.
- Dead variables, dead parameters, and unreachable branches that this branch added.
- Docstrings that describe behavior that this branch changed.

### Ask first - one grouped prompt for each category

- Each behavior change, also a small one, and also an "obvious" bug fix.
- Refactors that change call sites or public signatures.
- Test changes, except a fix of an assertion that is clearly wrong.
- New snapshot or golden files.
- A dependency that you add, upgrade, or remove.
- A change to code that this branch did not add (out-of-scope cleanup).
- A concurrency change. Concurrency changes are almost never low risk. This rule is about edits
  only. `review-branch` finds concurrency problems in its "Concurrency & data races" bucket.

### Permitted git writes

Only these five. All other git writes are forbidden.

- `git absorb --base <parent>`, with no `--and-rebase`.
- `git commit --fixup=<sha>`, where `<sha>` is in `<parent>..HEAD`. A fixup for a SHA outside that
  range changes the parent history on autosquash. In that case, use a normal commit.
- `git commit -m <msg>`, only when there is no fixup target.
- `history-rewrite.sh` (see "Commit history"), only after the user confirms, or in auto mode. It
  is the only permitted history rewrite. Never run `git rebase` yourself.
- The git writes of the `deslop` pass (step 7), which include the `amend!` commits from
  `reword-fixup.sh`.

Also permitted: read and stage commands (`git add`, `git status`, `git diff`, `git blame`,
`git log`).

Forbidden: `git push`, `git rebase` by hand, `git commit --amend`, `git reset --hard`,
`git absorb --and-rebase`, PR and issue operations, and edits to files outside the branch diff.

## Commit history

Only for a self-review. `review-branch` does not do this check, because it also reviews the
branches of other people. Their history is not yours to change.

Goal: each commit on the branch has value by itself. Find only commits that must be squashed.

### Input

```
git log --reverse --format='%h %s' <parent>..HEAD
git log --reverse --name-only --format='--- %h %s' <parent>..HEAD
```

### Flag a commit if one of these is true

- **Repair subject** - the subject or the body tells that it repairs an earlier branch commit:
  "fix typo", "address review", "oops", "forgot", "adjust X", "revert of <earlier commit>".
- **Placeholder subject** - `wip`, `tmp`, `fix`, `stash`, `.`, or a subject that names no
  capability.
- **Repair content** - the commit changes only lines that an earlier branch commit added, and adds
  no capability that a reader can name.

Find the target: the earlier branch commit that added the lines that this commit changes. Use
`git blame` if the subject does not name it. If there is no target in the range, there is no
finding.

### Never flag

- A commit that has value by itself, also a small one.
- Merge commits, and all commits at or below `<parent>`.
- `fixup!` and `amend!` commits. `--autosquash` already puts them in the correct position.
- A commit that is too large or has more than one concern. Splits are out of scope for this skill.

### Report and confirm

Write one line for each suggestion:

```
<src-sha> "<src subject>" -> squash into <tgt-sha> "<tgt subject>"
```

Add `(reorder first)` if the two commits are not adjacent. Then ask one time. The user selects
apply or skip for each item. If there are no suggestions, tell the user in one line. In standalone
mode, skip the rest of this section.

### Rewrite

Only with the helper:

```
~/.claude/skills/review-me/history-rewrite.sh <parent> [<repair>:<target>...]
```

- Give one squash for each item that the user confirmed. Each squash is `<repair>:<target>`. The
  repair commit is newer than the target. Both SHAs must be in `<parent>..HEAD`.
- The script checks the squashes, saves a backup ref, and runs one
  `git rebase -i --autosquash <parent>`. This rebase also squashes all `fixup!` and `amend!`
  commits. The reorder occurs in that rebase. Do not reorder as a separate step before.
- On a conflict, the script stops the rebase, restores the branch, and exits `1`. Do not resolve
  the conflict and do not retry. Report the failure and the backup ref. Tell the user to squash by
  hand.
- The script prints `backup-ref`, `squashes-applied`, `commits-before`, `commits-after`, and
  `result`. The final reply shows only `backup-ref`.
- With `--dry-run` as the first argument, the script prints the plan and writes nothing.

If there are no confirmed items: in standalone mode, change nothing. In auto mode, run the script
with no squashes.

## Loop

0. **Precondition:** run `git status --porcelain`. If the output is not empty, stop. Show the
   changed paths and tell the user to stash or commit, then try again. Do not stash. The user's
   work and the work of this skill must stay separate.
1. Use `review-branch`. Read the report.
2. Put the findings in two groups: apply with no prompt, and ask first.
3. Apply the no-prompt fixes, file by file. If the files are independent, edit them in parallel.
4. For the ask-first findings, show **one** grouped prompt:
   - For each finding: the id, title, severity, files, and the proposed change in at most 3 lines.
   - The user selects apply or skip for each id.
   - Apply the items that the user approves.
5. Run the validation of the repo if you can find it: tests, type check, lint. Look in the
   `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, and similar
   files. If you find no validation, tell the user. Do not make up commands.
6. **Absorb pass.** Do this step only if the validation passed or there is no validation, and at
   least one fix was applied in this pass. The helper script does the git work. Do not run absorb,
   blame, or fixup by hand:

   ```
   ~/.config/ai/bin/git-absorb-fixes.sh <parent> <file>...
   ```

   - `<parent>`: the `parent:` value from the context of `review-branch`. Do not calculate it
     again.
   - `<file>...`: only the files that this skill changed in this pass. The script stages only these
     files (never `git add -A`) and runs `git absorb`. For each file that absorb does not fold, it
     makes a fixup for the in-range commit that `git blame` shows most.
   - The script prints a keyed block: `absorb-fixups`, `blame-fixups` (with `<sha> <file>` lines),
     `needs-message` (staged files with no in-range blame target), and `staged-remaining`.
   - For each `needs-message` file, write a one-line conventional commit message and run
     `git commit -m "<msg>" -- <file>`. The script does not do this step, because the message needs
     judgment.
7. **Writing pass (REQUIRED).** Only in the first pass, when the working tree is clean again: use
   `deslop` in branch mode (no arguments). It reads the writing rules, fixes prose and commit
   messages, and makes its own absorb and `amend!` commits. It asks about its deferred items in
   its own grouped prompt.
8. **Re-review.** If this pass changed no file, skip this step. The report on disk is still
   correct. Tell the user and go to step 10.

   Else, use `review-branch` again in **re-review mode** with three inputs: each file that this
   pass changed (the files of step 6 and the files that `deslop` changed in step 7), the files
   among them that got a behavior change, and the path of the previous report. It audits that
   scope plus one hop, and keeps the unresolved findings. Pass 1 can dispatch review agents. Later
   passes never do. Then go to step 2 with the new report.
9. Stop when no findings remain that you can apply with no prompt. This is the stop condition.
   **3 passes** is only a limit for a loop that does not stop. A normal run needs pass 1 to fix,
   and pass 2 to confirm and to find cascades: a removed dead symbol can make its neighbor dead.
   Pass 3 is a margin. If you get to the limit, the run does not converge: a fix adds a finding
   again, or two findings contradict each other. Tell the user which finding ids come back.
10. **History pass (last, one time).** After the loop ends, with a clean working tree, do "Commit
    history". It runs last, so that it sees the commits of steps 6 and 7.

## Final reply

Follow the rules in `review-branch` "Final reply", with this format:

```markdown
<one-line verdict: ready to push | needs your decision on N items | validation failed>

Review guide:
1. `<file>` - <why>

Needs decision:
- **H2** `<file>:<line>` - <short title>

Fixed:
- **M1** `<file>:<line>` - <short title>

Skipped:
- **L1** `<file>:<line>` - <short title>

Report: `<path>`
```

Add a line only in these cases:

- The validation failed: the command and the error.
- There is no validation command: no check verified the fixes.
- The working tree is dirty: the paths.
- `history-rewrite.sh` ran: the backup ref, and that only the push remains.
- The loop got to the pass limit: the ids that come back.

## Red flags - stop and think again

- You are about to apply a behavior change with no prompt because it "feels safe". Ask.
- You edit files outside `<parent>...HEAD` and did not ask first. Out-of-scope cleanup, also an
  `(adjacent)` finding, needs a confirmation for each item.
- You skip the re-review after fixes. Then the report on disk is wrong.
- You run a git write that is not in "Permitted git writes".
- You start the next pass with a dirty working tree. Stop and show the remaining changes.
- You do more than 3 passes. Stop and ask the user.
- You let `review-branch` dispatch review agents in a re-review pass. Only pass 1 can do this.
- You run the full audit in pass 2 or 3 and not re-review mode.
- You do a re-review after a pass that changed nothing, or you do not include the files of `deslop`
  in the scope list.
- You accept a re-review report that does not have a pass 1 finding that the scoped pass did not
  read.
- You finish without the `deslop` pass, or you fix wording by hand.
- You rewrite history without a confirmation for each item, or not through `history-rewrite.sh`.
  The only exception is the fixup squash in auto mode.
- You suggest a squash for a commit that has value by itself, or you suggest a split. Suggest only
  squashes of repair commits.
- You resolve a conflict after `history-rewrite.sh` stops. Give it back to the user.
- You do the history pass before the fix loop ends. Then the commit list is out of date.
