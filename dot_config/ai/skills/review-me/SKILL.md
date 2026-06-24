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

Extends `review-branch` with a fix loop. The audit + report logic is delegated — this skill only
adds **what to do about findings**, including folding fixes into their originating commits via
`git absorb`. Never pushes or rewrites history.

## When to use

- User asks to review their own branch and clean it up, or says "review me", "self-review", "tidy up
  my branch before PR".

**Do not use** when reviewing a teammate's branch or when the user only wants a report — use
`review-branch` directly.

## REQUIRED SUB-SKILL

Invoke `review-branch` to perform the audit and produce the report. Do not re-implement its git
discovery, checklist, severity scheme, or report writing. Read the generated report file before
proceeding.

## Fix policy

### Auto-apply — no prompt

- Typos in comments, strings, docs.
- Lint / format issues, applied via the repo's configured tool (e.g. `eslint --fix`, `ruff format`,
  `gofmt`, `cargo fmt`). Discover, don't hand-edit.
- Unused imports introduced by this branch.
- Dead variables / parameters / unreachable branches introduced by this branch.
- Comment-only edits clarifying _why_ (not _what_).
- Stale doc strings whose described behavior changed in this branch.

### Ask first — one grouped prompt per category

- Any behavior change, however small (including "obvious" bug fixes).
- Refactors that touch call sites or change public signatures.
- Test changes beyond fixing a clearly wrong assertion.
- Snapshot / golden-file regeneration.
- Dependency add / upgrade / remove.
- Any change to code **not introduced by this branch** (out-of-scope cleanup).
- Adding concurrency changes — flag and ask; concurrency is rarely "low risk".

### Git writes allowed

Only these three. Anything else is forbidden.

- `git absorb --base <parent>` (no `--and-rebase`).
- `git commit --fixup=<sha>` where `<sha>` is in `<parent>..HEAD`. Fixup against a SHA outside that
  range would corrupt parent history on autosquash — fall back to a normal commit instead.
- `git commit -m <msg>` for the no-fixup-target fallback only.

Plus the obvious read/stage helpers (`git add`, `git status`, `git diff`, `git blame`).

Hard no: `git push`, `git rebase`, `git commit --amend`, `git reset --hard`,
`git absorb --and-rebase`, PR/issue ops, edits to files outside the branch diff.

## Loop

0. **Precondition:** Run `git status --porcelain`. If non-empty, abort. Show the dirty paths and
   tell the user to stash or commit before retrying. Do not auto-stash — keeps user work and skill
   work separate.
1. Invoke `review-branch`. Read the resulting report.
2. Partition findings: auto-apply vs ask-first.
3. Apply auto-fixes, grouped by file. Use parallel edits when files are independent.
4. For ask-first findings, present **one** consolidated prompt:
   - Title, severity, files affected, proposed change in ≤3 lines each.
   - User picks per-item: apply / skip / defer.
5. Run repo's validation if discoverable: tests, typecheck, lint. Look in `package.json` scripts,
   `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, etc. If none found, say so — don't invent
   commands.
6. **Absorb pass.** Only if validation passed (or none was found) and at least one fix was applied
   this iteration. The git mechanics are deterministic - delegate them to the helper script, do not
   hand-run absorb/blame/fixup:

   ```
   ~/.config/ai/skills/review-me/absorb-fixes.sh <parent> <file>...
   ```

   - `<parent>`: the `parent:` value from `review-branch`'s context. Do not recompute it.
   - `<file>...`: only the files the skill modified this pass. The script stages exactly these
     (never `git add -A`), runs `git absorb`, and for each orphan it leaves, fixes up to the
     dominant in-range commit via blame.
   - It prints a keyed block: `absorb-fixups`, `blame-fixups` (with `<sha> <file>` lines),
     `needs-message` (files left staged because no in-range blame target exists), `staged-remaining`.
   - For each `needs-message` file: write a conventional one-liner and
     `git commit -m "<msg>" -- <file>`. This is the only orphan case the script defers, because the
     message is a judgment call. Note each as a new commit in the summary.
   - Surface the counts to the user.
7. Re-invoke `review-branch` to regenerate the report against the post-fix state.
8. Stop when no auto-fixable findings remain, or after **3 passes** (avoid loops). If still looping,
   surface why.

## Final turn-end summary

Short, scannable:

- Passes run: N
- Auto-fixes applied: count + one-line bullets
- Deferred (awaiting user): count + one-line bullets
- Validation: pass/fail/none-found, with command used
- Fixups via `git absorb`: N (against: `<sha-short> <subject>`, ...)
- Orphan hunks resolved by blame-based fixup: N (against: `<sha-short> <subject>`, ...)
- New commits added (no in-range fixup target): N (subjects: ...)
- Working tree: clean / dirty paths listed if not
- Remaining findings by severity: critical/major/minor/nit counts
- Next step for user: `git rebase -i --autosquash <parent>`, then push.

## Red flags — stop and reconsider

- About to auto-apply a behavior change because it "feels safe". It's not auto-applicable. Ask.
- Editing files outside `<parent>...HEAD`. Out of scope.
- Skipping the re-review pass after fixes — the report on disk would lie.
- Running any git write outside "Git writes allowed".
- Proceeding to the next pass with a non-clean working tree. Stop and surface the leftover.
- Looping past 3 passes. Stop and ask the user.
