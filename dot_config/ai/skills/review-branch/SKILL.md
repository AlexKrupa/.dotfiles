---
name: review-branch
description:
  Use when reviewing the currently checked-out git branch against its parent. Produces a Markdown
  report under ~/.ai/reviews/<repo>/ without modifying code, committing, or posting comments.
  Platform-agnostic (GitHub/GitLab/etc.) and author-agnostic (self or teammate).
---

# review-branch

Read-only audit of current branch vs parent. Output: single Markdown report at
`~/.ai/reviews/<repo>/<author>-<branch>.md`. No fixes, commits, pushes, or PR comments — ever.

## When to use

- User asks to review the current branch, this branch, the diff, "my changes", or a teammate's
  checked-out branch.
- Pre-merge gut check; second-pair-of-eyes pass before opening a PR.

**Do not use** for reviewing arbitrary commits, the working tree alone, or a specific PR number —
this skill only knows "current branch vs its parent".

## Prerequisites (run in parallel)

1. `git rev-parse --is-inside-work-tree` — abort with a clear message if not in a repo.
2. `git rev-parse --abbrev-ref HEAD` — current branch name. If it equals the resolved parent (e.g.
   on `main`), abort: "No parent diff to review."
3. Parent detection, in order:
   - `git rev-parse --abbrev-ref --symbolic-full-name @{u}` — upstream tracking branch (strip remote
     prefix).
   - Else first existing of `main`, `master`, `develop` via
     `git show-ref --verify --quiet refs/heads/<name>`.
   - Else abort: "Could not resolve parent branch."
4. `git status --porcelain` — if non-empty, note "Uncommitted changes present — not part of audit
   scope" in the report and list the files.
5. `git diff <parent>...HEAD --stat` and `git diff <parent>...HEAD` (three-dot — branch changes
   only, not parent drift).
6. `git log <parent>..HEAD --oneline` and `git shortlog -sn <parent>..HEAD`.

## Scope

Committed changes on the branch (`<parent>...HEAD`). Uncommitted edits are mentioned, not audited —
suggest the user commit or stash and re-run.

## Audit checklist

Group findings under these. Each finding cites `file:line` from the diff.

- **Correctness** — off-by-one, wrong conditions, null/undefined, async races, wrong operator (`<`
  vs `<=`).
- **Error handling & edge cases** — only what can actually happen; flag overcautious validation as a
  finding too.
- **Tests** — coverage of new behavior, missing edges, brittle assertions, flaky patterns.
- **Security** — input validation at trust boundaries, injection, secrets in code, authz checks.
- **Performance** — N+1, accidental quadratics, blocking I/O on hot paths, unbounded allocations.
- **Dead code** — unused imports/exports/vars, unreachable branches, leftover
  `console.log`/`print`/debug.
- **Public API / contracts** — breaking signature or schema changes, missing migration notes.
- **Style & consistency** — matches surrounding code (not personal preference; not lint-fixable
  trivia unless it actually breaks CI).
- **Docs & comments** — comments explain _why_ not _what_; stale docs; missing context on
  non-obvious code.
- **Dependencies** — new deps justified, version pinned, license acceptable.

## Severity

- `critical` — must fix before merge: real bugs, security holes, broken tests, data loss risk.
- `major` — should fix: likely bug, missing test for new behavior, perf regression, breaking change
  without migration.
- `minor` — worth fixing: small bug in unlikely edge case, mild duplication, unclear naming on a
  public symbol.
- `nit` — optional: bikeshed-grade polish.

Empty buckets are fine. Do not invent findings to fill them.

## Report file

- **Repo name:** worktree-aware.
  `basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`. Uses
  `--git-common-dir` so all worktrees of the same repo share one directory (common dir points at the
  main `.git`, not the worktree's `.git/worktrees/<name>`). Slugify same as below.
- **Author slug:** majority committer on the branch.
  `git shortlog -sn <parent>..HEAD | head -1 | sed -E 's/^ *[0-9]+\t//'` → slugify.
- **Branch slug:** slugify the branch name. **Replace `/` with `-`** explicitly so `feat/foo`
  becomes `feat-foo` and does not create a nested directory.
- **Slugifier:** lowercase, replace runs of non-`[a-z0-9]` with `-`, trim leading/trailing `-`.
- **Path:** `~/.ai/reviews/<repo-slug>/<author-slug>-<branch-slug>.md`. `mkdir -p` the parent.
  Overwrite if exists (re-runs supersede).

## Report structure (BLUF)

```markdown
# Review: <branch> (vs <parent>)

**TL;DR:** <1-2 sentence verdict — ship / fix-then-ship / major rework, plus the single biggest
risk.>

**Counts:** critical: N, major: N, minor: N, nit: N

---

- Author: <name>
- Commits: <n> Files: <n> +<add>/-<del>
- Uncommitted: <no | yes — file1, file2>
- Generated: <ISO date>

## Findings

### Critical

- **<file>:<line> — <short title>** What: <1-2 sentences> Fix: <prose, or ≤3-line snippet>

### Major

...

### Minor

...

### Nit

...

## Out of scope / mentions

Pre-existing issues noticed but not introduced by this branch — mention, don't fix.
```

Omit empty severity sections. Reference `file:line`; do not paste surrounding context. Snippets only
when prose is unclear.

## Hard constraints

- **No edits** to source files.
- **No git mutations:** no `add`, `commit`, `amend`, `push`, `rebase`, `reset`, `checkout` of other
  refs.
- **No PR/issue interaction:** no `gh pr`, no `glab mr`, no comments.
- Only filesystem write allowed: report file and its parent dir under `~/.ai/reviews/`.

## Red flags — stop and reconsider

- Diffing the working tree instead of `<parent>...HEAD`.
- Flagging pre-existing code outside the branch's diff under a severity bucket (it belongs in "Out
  of scope").
- Long code blocks in the report. Keep it scannable — the reader's eye should land on TL;DR + Counts
  first.
- Filling buckets with manufactured findings. Empty bucket > fake bucket.
- Touching any file other than the report.
