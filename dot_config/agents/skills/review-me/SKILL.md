---
name: review-me
description:
  Self-review of the current branch. Applies the fixes in code that the branch added and folds
  them into branch commits. Asks before changes to code that existed before the branch, and before
  large drift from the spec.
argument-hint: "[plan or spec path]"
disable-model-invocation: true
---

# review-me

This skill adds a fix loop to `review-diff`. `review-diff` does the audit and the report. This
skill decides what to do with the findings. It folds the fixes into the commits that they fix, with
`git absorb`. It never pushes. It rewrites history only through `git-squash-fixups.sh`, with no
prompt, and reports each squash.

## Auto mode

Auto mode is on when the caller tells you to use auto mode, for example the Superpowers branch
finish in the global/user instructions. A direct `/review-me` call is standalone mode.

## REQUIRED SUB-SKILLS

- `review-diff` - does the audit and writes the report. Do not do its git discovery, checklist,
  severity scheme, or report yourself. Read the report file before you continue.
- `deslop` - the writing pass on prose, comments, and commit messages (loop step 7). This pass is
  necessary. Do not edit wording or messages yourself. Do not skip it because the diff "has no
  docs". It also examines comments and commit messages.

## Spec and plan

`review-diff` checks the branch against the spec when it gets the spec path. Find the paths:

- Auto mode: the caller gives the plan path.
- Standalone mode: the path in `$ARGUMENTS`. If there is no argument and the conversation has a
  plan path, use that path.
- A plan gives the spec in its `**Spec:**` line. A spec path alone is also valid.

Give the spec and plan paths to `review-diff` in step 1 and in each re-review pass (step 8). If you
find no path, `review-diff` does no drift check.

## Fix policy

The severities are the `review-diff` severities: `critical`, `high`, `medium`, `low`.

### Apply with no prompt

- Findings of all severities in code that this branch added. If a fix is not clear, move the
  finding to the ask group. The re-review pass (step 8) checks the fixes.
- Typos in string literals. Comments and docs are for `deslop` (step 7).
- Lint and format problems. Use the configured tool of the repo, for example `eslint --fix`,
  `ruff format`, `gofmt`, or `cargo fmt`. Find the tool. Do not edit by hand.

Small drift from the plan does not block these fixes.

### Ask first - one grouped prompt

- Large drift from the spec. The spec or the code can be wrong, and only the user knows which.
- A change to code that this branch did not add (out-of-scope cleanup), also an `(adjacent)`
  finding.

### Permitted git writes

Only these five. All other git writes are forbidden.

- `git absorb --base <parent>`, with no `--and-rebase`.
- `git commit --fixup=<sha>`, where `<sha>` is in `<parent>..HEAD`. A fixup for a SHA outside that
  range changes the parent history on autosquash. In that case, use a normal commit.
- `git commit -m <msg>`, only when there is no fixup target.
- `git-squash-fixups.sh` (see "Commit history"). It is the only permitted history rewrite. Never
  run `git rebase` yourself.
- The git writes of the `deslop` pass (step 7), which include the `amend!` commits from
  `git-reword-fixup.sh`.

Also permitted: read and stage commands (`git add`, `git status`, `git diff`, `git blame`,
`git log`).

Forbidden: `git push`, `git rebase` by hand, `git commit --amend`, `git reset --hard`,
`git absorb --and-rebase`, PR and issue operations, and edits to files outside the branch diff.

## Commit history

Only for a self-review. `review-diff` does not do this check, because it also reviews the
branches of other people. Their history is not yours to change.

Find the commits to squash with the rules in `~/.config/agents/references/commit-history.md`.

The history pass (step 10) always runs `git-squash-fixups.sh`, also with no squashes. The script
squashes all `fixup!` and `amend!` commits in `<parent>..HEAD` into their targets. Also apply each
repair squash that the rules find. Do not ask before this rewrite, in both modes. The backup ref
lets the user undo it.

### Report

Write one line for each repair squash, for the final reply:

```
<src-sha> "<src subject>" -> squash into <tgt-sha> "<tgt subject>"
```

Add `(reorder first)` if the two commits are not adjacent.

### Rewrite

Only with the helper:

```
~/.config/agents/bin/git-squash-fixups.sh <parent> [<repair>:<target>...]
```

- Give one squash for each repair squash. Each squash is `<repair>:<target>`. The
  repair commit is newer than the target. Both SHAs must be in `<parent>..HEAD`.
- The script checks the squashes, saves a backup ref, and runs one
  `git rebase -i --autosquash <parent>`. This rebase also squashes all `fixup!` and `amend!`
  commits. The reorder occurs in that rebase. Do not reorder as a separate step before.
- On a conflict, the script stops the rebase, restores the branch, and exits `1`. Do not resolve
  the conflict and do not retry. Report the failure and the backup ref. Tell the user to squash by
  hand.
- If git-spice tracks the branch, the script also restacks the branches above it.
- The script prints `backup-ref`, `squashes-applied`, `commits-before`, `commits-after`,
  `upstack-restack`, and `result`.
- With `--dry-run` as the first argument, the script prints the plan and writes nothing.

## Loop

0. **Precondition:** run `git status --porcelain`. If the output is not empty, stop. Show the
   changed paths and tell the user to stash or commit, then try again. Do not stash. The user's
   work and the work of this skill must stay separate.
1. Use `review-diff` with the spec and plan paths (see "Spec and plan"). Read the report.
2. Put the findings in two groups: apply with no prompt, and ask first.
3. Apply the no-prompt fixes, file by file. If the files are independent, edit them in parallel.
4. For the ask-first findings, show **one** grouped prompt:
   - For each finding: the id, title, severity, files, and the proposed change in at most 3 lines.
   - The user selects apply or skip for each id.
   - Apply the items that the user approves.

   After steps 3 and 4, add each applied fix to a `## Fixes applied` section at the end of the
   report file, one line for each fix: ``- **<id>** `<file>:<line>` - <what changed>``. A
   re-review report keeps this section.
5. Run the validation of the repo if you can find it: tests, type check, lint. Look in the
   `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, and similar
   files. If you find no validation, tell the user. Do not make up commands.
6. **Absorb pass.** Do this step only if the validation passed or there is no validation, and at
   least one fix was applied in this pass. The helper script does the git work. Do not run absorb,
   blame, or fixup by hand:

   ```
   ~/.config/agents/bin/git-absorb-fixes.sh <parent> <file>...
   ```

   - `<parent>`: the `parent:` value from the context of `review-diff`. Do not calculate it
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

   Else, use `review-diff` again in **re-review mode** with the spec and plan paths and three
   inputs: each file that this pass changed (the files of step 6 and the files that `deslop`
   changed in step 7), the files among them that got a behavior change, and the path of the
   previous report. It audits that
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

Follow the rules in `review-diff` "Final reply", with this format:

```markdown
<one-line verdict: ready to push | needs your decision on N items | validation failed>

High-impact changes:
1. `<file>:<line>` - <what changes>

Review guide:
1. `<file>` - <why>

Needs decision:
- **H2** `<file>:<line>` - <short title>

Auto-fixed: <N> (<C> critical, <H> high, <M> medium, <L> low)

Check these fixes:
- **M1** `<file>:<line>` - <what changed, and why it needs your attention>

Skipped:
- **L1** `<file>:<line>` - <short title>

📄 Report: `<path>`
```

The `Auto-fixed:` line counts all fixes of `## Fixes applied` in the report. The report keeps the
full list. Write a "Check these fixes:" item for each `critical` and `high` fix, and for each fix
that changes behavior that a user sees. With no such fix, omit the block.

Add a line only in these cases:

- The validation failed: the command and the error.
- There is no validation command: no check verified the fixes.
- The working tree is dirty: the paths.
- `git-squash-fixups.sh` changed commits: the lines of "Report", the count of squashed `fixup!`
  and `amend!` commits, and the backup ref. If the restack failed, the script error.
- The loop got to the pass limit: the ids that come back.

## Red flags - stop and think again

- You auto-fix code that this branch did not add, or large drift from the spec. Ask.
- You edit files outside `<parent>...HEAD` and did not ask first. Out-of-scope cleanup, also an
  `(adjacent)` finding, needs a confirmation for each item.
- You skip the re-review after fixes. Then the report on disk is wrong.
- You run a git write that is not in "Permitted git writes".
- You start the next pass with a dirty working tree. Stop and show the remaining changes.
- You do more than 3 passes. Stop and ask the user.
- You let `review-diff` dispatch review agents in a re-review pass. Only pass 1 can do this.
- You run the full audit in pass 2 or 3 and not re-review mode.
- You do a re-review after a pass that changed nothing, or you do not include the files of `deslop`
  in the scope list.
- You accept a re-review report that does not have a pass 1 finding that the scoped pass did not
  read.
- You finish without the `deslop` pass, or you fix wording by hand.
- You rewrite history not through `git-squash-fixups.sh`, or you ask before the history pass.
- You suggest a squash for a commit that has value by itself, or you suggest a split. Suggest only
  squashes of repair commits.
- You resolve a conflict after `git-squash-fixups.sh` stops. Give it back to the user.
- You do the history pass before the fix loop ends. Then the commit list is out of date.
