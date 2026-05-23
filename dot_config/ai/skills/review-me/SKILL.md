---
name: review-me
description:
  Use when self-reviewing the currently checked-out branch and wanting low-risk fixes applied
  automatically. Runs the review-branch audit, then applies safe fixes (typos, lint, dead imports,
  doc tweaks) without asking and pauses for confirmation before behavior changes or broad refactors.
---

# review-me

Extends `review-branch` with a fix loop. The audit + report logic is delegated — this skill only
adds _what to do about findings_. Never commits or pushes.

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

### Never

- `git commit`, `git amend`, `git push`, `git rebase`, `git reset --hard`, `git checkout <other>`.
- Open, close, or comment on PRs / issues.
- Edit files outside the branch's diff.

## Loop

1. Invoke `review-branch`. Read the resulting report.
2. Partition findings: auto-apply vs ask-first.
3. Apply auto-fixes, grouped by file. Use parallel edits when files are independent.
4. For ask-first findings, present **one** consolidated prompt:
   - Title, severity, files affected, proposed change in ≤3 lines each.
   - User picks per-item: apply / skip / defer.
5. Run repo's validation if discoverable: tests, typecheck, lint. Look in `package.json` scripts,
   `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, etc. If none found, say so — don't invent
   commands.
6. Re-invoke `review-branch` to regenerate the report against the post-fix state.
7. Stop when no auto-fixable findings remain, or after **3 passes** (avoid loops). If still looping,
   surface why.

## Final turn-end summary

Short, scannable:

- Passes run: N
- Auto-fixes applied: count + one-line bullets
- Deferred (awaiting user): count + one-line bullets
- Validation: pass/fail/none-found, with command used
- Remaining findings by severity: critical/major/minor/nit counts
- **Nothing committed or pushed.**

## Red flags — stop and reconsider

- About to auto-apply a behavior change because it "feels safe". It's not auto-applicable. Ask.
- Editing files outside `<parent>...HEAD`. Out of scope.
- Skipping the re-review pass after fixes — the report on disk would lie.
- Running `git commit` / `git push` / `gh pr ...`. Never, regardless of how clean the branch looks.
- Looping past 3 passes. Stop and ask the user.
