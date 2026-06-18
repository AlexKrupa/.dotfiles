---
name: review-branch
description:
  Diffs the current git branch against its parent and writes a read-only Markdown report under
  ~/.ai/<repo>/reviews/. Called as a sub-skill by review-me (self-review + fixes) and review-gitlab
  (MR context); run directly only when the user names it. Do not pick it for a plain "review my
  branch" request - use review-me or review-gitlab, which call it themselves. Platform-agnostic
  (GitHub/GitLab/etc.) and author-agnostic (self or teammate).
---

# review-branch

Read-only audit of current branch vs parent. Output: single Markdown report at
`~/.ai/<repo>/reviews/<branch>-<author>.md`. No fixes, commits, pushes, or PR comments — ever.

## When to use

Shared audit step, not a standalone entry point. Run it when:

- `review-me` or `review-gitlab` invoke it as their REQUIRED SUB-SKILL.
- The user names it directly (slash command or "run review-branch").

Do not pick it on your own for a "review my branch" or "review the diff" request. Those go through
`review-me` (self-review) or `review-gitlab` (MR), which call this skill themselves.

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

## Parent override

A caller (typically another skill, e.g. `review-gitlab`) may supply an explicit parent branch to
diff against. When given, skip steps 3 and 4 of parent detection and use it directly. Validate the
ref exists locally (`git rev-parse --verify <parent>`); abort with a clear message if not. Note the
override source in the report's header so the reader knows the parent was not auto-detected.

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

Run the helper to get the destination path (absolute path, since skill cwd is the user's repo, not
this dir). Do not re-implement repo / author / branch resolution inline.

    path="$(~/.config/ai/skills/review-branch/report-path.sh <parent>)"

The helper handles: worktree-aware main-repo name (via `--git-common-dir`, so every worktree of
`foo` writes under one directory regardless of the worktree folder's own name), slugification
(including diacritic transliteration, e.g. `Józef Mąka` → `jozef-maka`), branch-name `/`→`-`
flattening, majority-author detection, and `mkdir -p` of the parent. Prints the absolute path on
stdout. Overwrite the file if it exists (re-runs supersede).

Optional second arg `prefix` → `<prefix>-<branch>-<author>.md` (the prefix is slugified too).
Callers like `review-gitlab` pass `mr-<iid>` this way. Omit it for the plain `<branch>-<author>.md`
form.

Do **not** substitute `git rev-parse --show-toplevel` — that returns the worktree root and breaks
the main-repo grouping convention.

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
- Only filesystem write allowed: report file and its parent dir under `~/.ai/<repo>/reviews/`.

## Red flags — stop and reconsider

- Diffing the working tree instead of `<parent>...HEAD`.
- Flagging pre-existing code outside the branch's diff under a severity bucket (it belongs in "Out
  of scope").
- Long code blocks in the report. Keep it scannable — the reader's eye should land on TL;DR + Counts
  first.
- Filling buckets with manufactured findings. Empty bucket > fake bucket.
- Touching any file other than the report.
