---
name: review-me
description:
  Use when self-reviewing the currently checked-out branch and wanting low-risk fixes (typos, lint,
  dead imports, doc tweaks) applied and folded into branch commits automatically. Triggers on
  "review me", "self-review", "tidy up my branch", "clean up before PR". Pauses for confirmation
  before behavior changes or broad refactors.
disable-model-invocation: true
---

# review-me

Extends `review-branch` with a fix loop. The audit + report logic is delegated - this skill only
adds **what to do about findings**, including folding fixes into their originating commits via
`git absorb`. Never pushes or rewrites history.

## When to use

- User asks to review their own branch and clean it up, or says "review me", "self-review", "tidy up
  my branch before PR".

**Do not use** when reviewing a teammate's branch or when the user only wants a report - use
`review-branch` directly.

## REQUIRED SUB-SKILLS

- `review-branch` - performs the audit and produces the report. Do not re-implement its git
  discovery, checklist, severity scheme, or report writing. Read the generated report file before
  proceeding.
- `deslop` - the writing pass over prose and commit messages (loop step 7). REQUIRED, not optional:
  do not hand-edit wording or messages yourself, and do not skip it because the diff "has no docs" -
  it covers comments and commit messages too.

## Fix policy

### Auto-apply - no prompt

- Typos in comments, strings, docs.
- Lint / format issues, applied via the repo's configured tool (e.g. `eslint --fix`, `ruff format`,
  `gofmt`, `cargo fmt`). Discover, don't hand-edit.
- Unused imports introduced by this branch.
- Dead variables / parameters / unreachable branches introduced by this branch.
- Comment-only edits clarifying _why_ (not _what_).
- Stale doc strings whose described behavior changed in this branch.

### Ask first - one grouped prompt per category

- Any behavior change, however small (including "obvious" bug fixes).
- Refactors that touch call sites or change public signatures.
- Test changes beyond fixing a clearly wrong assertion.
- Snapshot / golden-file regeneration.
- Dependency add / upgrade / remove.
- Any change to code **not introduced by this branch** (out-of-scope cleanup).
- Adding concurrency changes - flag and ask. Concurrency is rarely "low risk". (This decides whether
  to auto-edit. Detection of concurrency issues is review-branch's "Concurrency & data races"
  bucket, a separate axis.)

### Git writes allowed

Only these four. Anything else is forbidden.

- `git absorb --base <parent>` (no `--and-rebase`).
- `git commit --fixup=<sha>` where `<sha>` is in `<parent>..HEAD`. Fixup against a SHA outside that
  range would corrupt parent history on autosquash - fall back to a normal commit instead.
- `git commit -m <msg>` for the no-fixup-target fallback only.
- `history-rewrite.sh` (see "Commit history"), and only after the user confirms. It is the single
  permitted history rewrite - never run `git rebase` yourself.

Plus the obvious read/stage helpers (`git add`, `git status`, `git diff`, `git blame`, `git log`).

Hard no: `git push`, a hand-run `git rebase`, `git commit --amend`, `git reset --hard`,
`git absorb --and-rebase`, PR/issue ops, edits to files outside the branch diff.

## Commit history

Self-review only. `review-branch` does not check this - it also runs for teammate reviews, where
history is not yours to restructure.

Goal: every commit on the branch is independently valuable. Find over-fragmentation only.

### Input

```
git log --reverse --format='%h %s' <parent>..HEAD
git log --reverse --name-only --format='--- %h %s' <parent>..HEAD
```

### Flag a commit when any of these holds

- **Repair subject** - the subject or body says it repairs an earlier branch commit: "fix typo",
  "address review", "oops", "forgot", "adjust X", "revert of <earlier commit>".
- **Placeholder subject** - `wip`, `tmp`, `fix`, `stash`, `.`, or any subject naming no capability.
- **Repair content** - the commit only changes lines an earlier branch commit added, and adds no
  capability a reader could name.

Pick the target: the earlier branch commit that introduced the lines this one changes. Use
`git blame` when the subject alone does not name it. No identifiable in-range target means no
finding.

### Never flag

- A commit that stands on its own, even a small one.
- Merge commits, and anything at or below `<parent>`.
- `fixup!` / `amend!` commits - `--autosquash` places those already.
- A commit that is too large or mixes concerns. Splitting is out of scope for this skill.

### Report and confirm

One line per suggestion, one sentence each:

```
<src-sha> "<src subject>" -> squash into <tgt-sha> "<tgt subject>"
```

Add `(reorder first)` when the two are not adjacent. Then ask once. The user picks per item: apply
or skip. No suggestions means say so in one line and skip the rest.

### Rewrite

Only for confirmed items, only through the helper:

```
~/.claude/skills/review-me/history-rewrite.sh <parent> <source>:<target>...
```

- Each spec reads `<newer>:<older>`. Both SHAs must lie in `<parent>..HEAD`.
- The script validates the specs, saves a backup ref, and runs one
  `git rebase -i --autosquash <parent>`. Reordering happens inside that same rebase - do not reorder
  first as a separate step.
- On conflict it aborts, restores the branch, and exits 1. Do not resolve the conflict and do not
  retry. Report the failure and the backup ref, and tell the user to squash by hand.
- It prints `backup-ref`, `squashes-applied`, `commits-before`, `commits-after`, `result`. Surface
  these.
- `--dry-run` as first arg prints the plan and writes nothing.

If the user declines every item, change nothing.

## Loop

0. **Precondition:** Run `git status --porcelain`. If non-empty, abort. Show the dirty paths and
   tell the user to stash or commit before retrying. Do not auto-stash - keeps user work and skill
   work separate.
1. Invoke `review-branch`. Read the resulting report.
2. Partition findings: auto-apply vs ask-first.
3. Apply auto-fixes, grouped by file. Use parallel edits when files are independent.
4. For ask-first findings, present **one** consolidated prompt:
   - Finding id, title, severity, files affected, proposed change in ≤3 lines each.
   - User picks per-item by id: apply / skip / defer.
5. Run repo's validation if discoverable: tests, typecheck, lint. Look in `package.json` scripts,
   `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, etc. If none found, say so - don't invent
   commands.
6. **Absorb pass.** Only if validation passed (or none was found) and at least one fix was applied
   this iteration. The git mechanics are deterministic - delegate them to the helper script, do not
   hand-run absorb/blame/fixup:

   ```
   ~/.claude/skills/review-me/absorb-fixes.sh <parent> <file>...
   ```

   - `<parent>`: the `parent:` value from `review-branch`'s context. Do not recompute it.
   - `<file>...`: only the files the skill modified this pass. The script stages exactly these
     (never `git add -A`), runs `git absorb`, and for each orphan it leaves, fixes up to the
     dominant in-range commit via blame.
   - It prints a keyed block: `absorb-fixups`, `blame-fixups` (with `<sha> <file>` lines),
     `needs-message` (files left staged because no in-range blame target exists), and
     `staged-remaining`.
   - For each `needs-message` file: write a conventional one-liner and
     `git commit -m "<msg>" -- <file>`. This is the only orphan case the script defers, because the
     message is a judgment call. Note each as a new commit in the summary.
   - Surface the counts to the user.
7. **Writing pass (REQUIRED).** First pass only, once the working tree is clean again: invoke
   `deslop` in branch mode (no args). It reads the writing rules, fixes prose and commit messages,
   and does its own absorb and `amend!` commits. Its deferred items join this skill's ask-first
   prompt.
8. **Re-review.** Skip this step when the pass changed no file. Nothing moved, so the report on disk
   is still accurate. Say so and go to step 10.

   Otherwise re-invoke `review-branch` in **re-review mode** with three inputs: every file this pass
   modified (step 6's list plus the files `deslop` touched in step 7), which of them got a behavior
   change, and the path of the previous report. It audits that scope plus one hop, and keeps
   unresolved findings. Pass 1 may fan out review agents, later passes never do.
9. Stop when no auto-fixable findings remain. That is the stop condition. **3 passes** is only a
   runaway cap: a converging run needs pass 1 to fix and pass 2 to confirm plus catch cascades (a
   removed dead symbol makes its neighbour dead). Pass 3 is the margin. Hitting the cap means the
   run is not converging - a fix is reintroducing a finding, or two findings contradict each other.
   Surface which finding ids keep coming back.
10. **History pass (last, once).** After the loop ends and with a clean working tree, run the
    "Commit history" section. It runs last so it sees the commits steps 6 and 7 added.

## Final turn-end summary

Short, scannable:

- Passes run: N
- Auto-fixes applied: count + one-line bullets
- Deferred (awaiting user): count + one-line bullets
- Validation: pass/fail/none-found, with command used
- Writing pass: files deslopped, commit messages reworded (or `skipped - <reason>`)
- Fixups via `git absorb`: N (against: `<sha-short> <subject>`, ...)
- Orphan hunks resolved by blame-based fixup: N (against: `<sha-short> <subject>`, ...)
- New commits added (no in-range fixup target): N (subjects: ...)
- Commit history: N squashes suggested, N applied, N declined (or `none suggested`). On a rewrite,
  the backup ref and the before/after commit counts
- Working tree: clean / dirty paths listed if not
- Remaining findings: counts by severity, listing the ids left unresolved (e.g. `B2`, `C1`)
- Next step for user: `git rebase -i --autosquash <parent>`, then push. Omit the rebase when
  `history-rewrite.sh` already ran it - say the history is squashed and only push remains.

## Red flags - stop and reconsider

- About to auto-apply a behavior change because it "feels safe". It's not auto-applicable. Ask.
- Editing files outside `<parent>...HEAD` without asking first. Out-of-scope cleanup, including an
  `(adjacent)` finding, needs a per-item confirmation.
- Skipping the re-review pass after fixes - the report on disk would be wrong.
- Running any git write outside "Git writes allowed".
- Proceeding to the next pass with a non-clean working tree. Stop and surface the leftover.
- Looping past 3 passes. Stop and ask the user.
- Letting `review-branch` fan out review agents on a re-review pass. Pass 1 only.
- Re-running the full audit on pass 2 or 3 instead of re-review mode.
- Re-reviewing after a pass that changed nothing, or leaving `deslop`'s files out of the scope list.
- Accepting a re-review report that lost a pass-1 finding the scoped pass never read.
- Finishing without the `deslop` pass, or fixing wording by hand instead of invoking it.
- Rewriting history without an explicit per-item confirmation, or through anything other than
  `history-rewrite.sh`.
- Suggesting a squash for a commit that stands on its own, or suggesting a split. Over-fragmentation
  only.
- Resolving a conflict after `history-rewrite.sh` aborts. Hand it back to the user.
- Running the history pass before the fix loop ends - the commit list would be stale.
