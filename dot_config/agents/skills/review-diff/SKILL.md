---
name: review-diff
description:
  Audits a git diff and writes a read-only Markdown report under ~/.ai/<repo>/reviews/. The diff is
  the current branch vs its parent (default), uncommitted or staged changes (optionally with the
  branch), or a commit or commit range. Called as a sub-skill by review-me (self-review + fixes) and
  review-gitlab (MR context). Run directly only when the user names it. Do not pick it for a plain
  "review my branch" or "review my changes" request - use review-me or review-gitlab, which call
  it themselves. Platform-agnostic (GitHub/GitLab/etc.) and author-agnostic (self or teammate).
---

# review-diff

<SUBAGENT-STOP>
Dispatched as a review agent by this skill? Skip "Run the audit", and skip "Gather context" except
any subsection your assignment names. Your prompt already has the diff context. Run the emitted
`diff-command`, audit only your assigned checklist items, and return the findings to the caller.
Never dispatch agents. Never write a file.
</SUBAGENT-STOP>

Read-only audit of a git diff. Output: single Markdown report at
`~/.ai/<repo>/reviews/<date>-[<scope>-]<branch>-<author>.md`. No fixes, commits, pushes, or PR
comments.

## When to use

Shared audit step, not a standalone entry point. Run it when:

- `review-me` or `review-gitlab` invoke it as their REQUIRED SUB-SKILL.
- The user names it directly (slash command or "run review-diff").

Do not pick it on your own for a "review my branch" or "review the diff" request. Those go through
`review-me` (self-review) or `review-gitlab` (MR), which call this skill themselves.

**Do not use** for a PR or MR number - `review-gitlab` resolves the MR. This skill only reads
local refs and the local working tree.

## Diff scope

Select the diff scope from the user's words or the caller's arguments. Pass the helper args below.

| Request | Helper args | Diff |
|---|---|---|
| nothing, or a branch name | `[parent]` | branch commits vs parent |
| "uncommitted", "working tree", "my changes" | `--uncommitted` | working tree + untracked files vs HEAD |
| "staged", "index" | `--staged` | index vs HEAD |
| "uncommitted" plus "with the branch" | `--uncommitted --with-branch [parent]` | branch commits + working tree + untracked files |
| "staged" plus "with the branch" | `--staged --with-branch [parent]` | branch commits + index |
| a commit SHA or ref that is not the parent, or a range `A..B` | `--rev <rev>` | one commit vs its first parent, or the commits in `B` not in `A` |

A bare ref is ambiguous: `main` is a parent, `a1b2c3d` or `HEAD~2` is a commit. If you cannot tell,
ask.

Uncommitted edits in `branch` or `rev` scope, and unstaged edits in the staged scopes, are not in
the diff. Mention them in the header. Do not audit them.

## Gather context

Run the helper with the args from "Diff scope". It resolves branch/parent deterministically and
prints a keyed metadata block. Use an absolute path (skill cwd is the user's repo):

    ~/.config/ai/bin/git-diff-context.sh [parent-override]
    ~/.config/ai/bin/git-diff-context.sh --uncommitted | --staged [--with-branch [parent-override]]
    ~/.config/ai/bin/git-diff-context.sh --rev <rev | A..B>

It runs cheap guards before any diff, in fail-fast order: repo check, branch name, parent detection,
the empty-diff guard, `git status`, diffstat, commit log, and author shortlog. It
aborts (exit 1, message on stderr) when not in a repo, when the diff scope is empty, or when parent
is unresolved - relay that message and stop.

Parent detection (`branch` and the `branch-*` scopes, no override arg): if git-spice tracks the
current branch, its base branch is the immediate stack parent. Else the nearest local branch that
is a strict ancestor of HEAD is the immediate stack parent. If that branch is mainline
(`main`/`master`/`develop` or a remote default branch), the base is mainline: the script anchors on
the remote-tracking ref from the last fetch (e.g. `origin/main`), so a stale local mainline does not
pollute the diff with other people's commits. It does not fetch. If the remote-tracking ref does
not exist, it falls back to the local mainline ref. An intermediate stack parent stays anchored on
its local tip (its split point is your local tip).

Output keys: `scope` (`branch` | `uncommitted` | `staged` | `branch-uncommitted` | `branch-staged`
| `rev`), `branch` (the current branch), `tip` (the branch, or the end of a `rev` range), `parent`,
`parent-source` (`ancestor-branch` | `default-branch` | `override` | `head` | `rev`),
`uncommitted` (`yes`/`no`), `log-range`, `report-prefix`,
`diff-command`, then `## Diffstat`, `## Commits`, `## Authors (shortlog)`, `## Uncommitted`
(`git status --porcelain`).

The script does **not** print the full diff (unbounded). Run the emitted `diff-command` yourself to
get the reviewable content. In the scopes with branch commits, it diffs from the merge base, so
parent drift stays out of the diff. The `uncommitted` and `staged` scopes diff against `HEAD`. In
the uncommitted scopes, `git diff` does not show untracked files: read each `??` file from
`## Uncommitted` in full and audit it as a new file. Count these files in the diffstat file count.
Surface `parent` and `parent-source` in the report header, so the reader knows what the diff was
anchored against.

### Project docs / conventions

After resolving the diff, gather the project's own documented conventions so findings can be checked
against them. Run the docs helper (absolute path - skill cwd is the user's repo):

    ~/.claude/skills/review-diff/docs-index.sh

It enumerates tracked docs via `git ls-files` (so gitignored `build/`, `.gradle/`, `node_modules/`,
and generated doc output are excluded automatically - no hardcoded skip list) across three groups:
doc dirs (`docs/`, `documentation/`, `doc/`), root convention files (`CONTRIBUTING*`, `README*`,
`ARCHITECTURE*`, `STYLE*`, `docs/adr/**`), and agent instruction files (`CLAUDE.md`, `AGENTS.md`,
`GEMINI.md`, `.cursorrules`). It emits a cheap index - a `docs-found: N` count, then per doc a
`file:` line with that file's headings indented beneath it. It reads no file bodies and is
read-only.

Then **select, don't read everything**: match the index headings and paths against the branch's
changed files and diff topics. Open in full only the docs that plausibly govern what the branch
touched (e.g. skip a snapshot-testing doc when the branch has no snapshot tests). `docs-found: 0`
means the repo has no discoverable conventions - skip the docs-alignment check entirely and produce
no docs-related findings.

Record which docs you actually opened in the report's required `Convention docs consulted:` header
line (see "Report structure"). Use `none found` only when the helper reported `docs-found: 0`.

### Existing implementations

Only when the diff adds something meant for reuse (shared helper, extension function, base class,
interface, generic wrapper): search the repo for equivalent behavior before treating it as new - by
name, by signature, and in the module where such a thing would already live. A duplication finding
requires the existing symbol's `file:line`. If you did not find one, there is no finding. Skip this
step entirely when the diff adds no reusable symbol.

**Parent override:** pass the parent branch as the last arg (callers like `review-gitlab` do this).
The script validates the ref exists locally and reports `parent-source: override`.

## Run the audit

### Re-review mode

A caller that already ran this skill, applied fixes, and wants a fresh report uses re-review mode.
It passes the files it modified, which of those got a behavior change, and the previous report path.
`review-me` step 8 does this.

Re-review mode is always single-agent. Never fan out - the scope is too small to justify it.

**Read the previous report first.** A same-day re-run resolves to the same path. Writing before
reading destroys the findings you must keep.

**Context.** Still run `git-diff-context.sh` with the same scope args - the header needs the
post-fixup commit count and diffstat. Skip `docs-index.sh` and open no docs. Copy the previous
report's `Convention docs consulted:` line as is.

**Scope.** The named files, plus one hop out: direct callers and callees of any symbol the caller
removed or renamed. Nothing else. A removed export can leave a now-unused symbol in a file nobody
edited - one hop catches that, a plain changed-files list does not.

**Checklist.** On a file that got a behavior change, run the full checklist. On a file that got only
typo, lint, dead-code, or comment fixes, run Dead code, Docs & comments, and Style & consistency
only.

**Keep old findings.** Copy every unresolved finding from the previous report into the new one -
text, severity, and **id** unchanged. A scoped pass did not read that code. It cannot clear it.
Give new findings the next free ordinal in their severity section. Never renumber a copied id. The
caller already told the user "`H2` unresolved", and a pass that renumbers makes that reference point
somewhere else. Dropping a copied finding is a silent regression - the caller reads the new report
as complete.

### Full audit

Count the files in the diffstat.

**20 or fewer:** audit every checklist item yourself in one pass. Skip to "Audit checklist".

**More than 20:** dispatch three review agents in parallel, in one message, then merge their output.
Keep the context you already gathered - the agents do not re-run the helpers.

### The three agents

Every agent prompt has the same preamble: the `parent` value, the `diff-command`, the diffstat, in
the uncommitted scopes the untracked files to audit, and this instruction - "Read
`~/.claude/skills/review-diff/SKILL.md`. Audit only the checklist items
named below. Return each finding in the report bullet format with its severity. No ids. Write no
files."

| Agent | Extra input | Checklist items |
|---|---|---|
| defect | none | Correctness, Concurrency & data races, Error handling & edge cases, Tests, Security, Performance, Public API / contracts |
| docs | the `docs-index.sh` output | Conventions & docs alignment, Docs & comments, Style & consistency, Dependencies |
| structure | none | Simplicity (with its adjacent radius), Dead code, the "Existing implementations" search, and "High-impact changes" |

The docs agent also returns the docs it opened, for the `Convention docs consulted:` header line.
Only the structure agent runs the repo-wide symbol search. It also returns the high-impact items in
the report item format.

### Merge

1. Verify every returned finding and high-impact item yourself against the diff: the `file:line`
   exists and the claim holds. Agent output is unverified. Drop what you cannot confirm.
2. Two findings on the same `file:line` with the same claim are one finding. Keep the higher
   severity and the clearer text.
3. Assign ids after dedup, per "Report structure".
4. Write the report yourself.

## Audit checklist

Group findings under these. Each finding cites `file:line`. Before writing any finding, verify it
against the actual diff/code: the cited `file:line` exists, the operator or condition is as
claimed, and the code is in audit scope. Audit scope is the branch's diff, plus the adjacent radius
that **Simplicity** defines below - that radius is the only reach outside the diff, and no other
checklist item uses it. Code outside audit scope goes to "Out of scope". Drop any finding you cannot
confirm.

- **Correctness** - off-by-one, wrong conditions, null/undefined, wrong operator (`<` vs `<=`).
- **Concurrency & data races** - shared mutable state without sync, lock ordering / deadlock,
  check-then-act atomicity, missing memory visibility, blocking call inside an async/coroutine
  context, unbounded parallelism. Always checked. Go deeper when the diff touches core
  concurrency code (lock primitives, coroutine/async infrastructure, low-level shared utilities,
  caches, channels). Only races that can actually happen - do not manufacture findings.
- **Conventions & docs alignment** - check the branch against the docs selected in "Gather context":
  (1) code contradicts a documented convention (naming, layering, error-handling pattern, "always
  use util X"). (2) The branch changes behavior a doc describes without updating that doc. (3) The
  branch adds a pattern or public API the docs say must be documented, but no doc was added. Cite
  the doc source in the finding, e.g. `violates docs/testing.md:L20`. Only when docs were found.
  Never invent a convention the docs do not state.
- **Error handling & edge cases** - only what can actually happen. Flag overcautious validation as a
  finding too.
- **Tests** - coverage of new behavior, missing edges, brittle assertions, flaky patterns. Also
  excessive mocking (mocking what you own / value objects), and asserting implementation detail over
  behavior.
- **Security** - input validation at trust boundaries, injection, secrets in code, authz checks.
- **Performance** - N+1, accidental quadratics, blocking I/O on hot paths, unbounded allocations.
- **Dead code** - unused imports/exports/vars, unreachable branches, leftover
  `console.log`/`print`/debug.
- **Simplicity** - avoidable complexity in code that works (YAGNI): single-use methods/vars/consts
  clearer inlined, wrappers/indirection/file splits with one caller, single-impl interface within
  the same module (cross-module `api`/`impl` splits can be fine), speculative params/config/hooks
  for futures that don't exist, flag-argument functions, deep nesting that collapses to guard
  clauses, reinventing stdlib or an existing util instead of reusing it (cite the existing symbol's
  `file:line` - no citation, no finding), a new shared or public utility with one caller that
  belongs private to it, a shallow type or layer whose methods only forward to one collaborator and
  add no behavior. Flag only when the simpler form is clearly better, not preference.

  _Adjacent scope._ These criteria apply one hop out from the diff as well as inside it. In scope:
  (1) the whole body of every file in the diffstat, not only the changed hunks. (2) Direct callees -
  the functions and types the changed lines call. (3) Direct callers of the symbols the branch
  changed. Stop there. A callee of a callee is out.

  Widen to the enclosing module or package only when the branch already changes the architecture
  there: it adds or removes a layer, moves a boundary, or changes a public interface or its
  implementations. A branch that only edits function bodies stays at one hop.

  A finding outside the diff takes the `(adjacent)` suffix in its title, is capped at `medium`, and
  states its count as evidence - callers, implementations, or forwarding methods. No count, no
  finding.
- **Public API / contracts** - breaking signature or schema changes, missing migration notes.
- **Style & consistency** - matches surrounding code (not personal preference, not lint-fixable
  trivia unless it breaks CI).
- **Docs & comments** - per `~/.claude/rules/code.md` (`## Comments (inline and doc)`) and
  `~/.claude/rules/documenting.md`, scrutinize each comment the branch adds or changes on two
  axes:
  - _why not what_: the comment explains the reason for the code, not a restatement of what the code
    does. Flag any comment whose content a reader could infer from the surrounding code itself
    (paraphrased control flow, obvious assignments, method-name echoes). A comment is justified only
    by a non-obvious choice, constraint, or workaround.
  - _brevity_: the comment is short enough to grasp at a glance - no wall-of-text, no inflated
    language. Flag verbose comments a human must read through. The fix is to cut to the essential
    _why_, not to expand.

  Also: stale docs, and missing context on non-obvious code.
- **Dependencies** - new deps justified, version pinned, license acceptable.

## Severity

- `critical` - must fix before merge: bugs, security holes, broken tests, data loss risk.
- `high` - should fix: likely bug, missing test for new behavior, perf regression, breaking change
  without migration.
- `medium` - worth fixing: small bug in unlikely edge case, mild duplication, unclear naming on a
  public symbol.
- `low` - optional polish.

An `(adjacent)` finding is capped at `medium`. Code the branch did not introduce cannot block a
merge.

Empty buckets are fine. Do not invent findings to fill them.

## High-impact changes

Read `~/.config/ai/references/review-guide.md`, section "High-impact changes". It has the criteria
and the soft limit.

Findings are defects. High-impact items are correct and intended changes. An intended change is not
a finding only because it is hard to undo or affects many places. Put it here, not under a
severity. When the change also has a defect (for example, a renamed stored field with no
migration), write the finding too, and cite its id in the item.

A new shared symbol with few callers is not wide reach. Simplicity covers it.

When the diff has no item, omit the section.

In re-review mode, copy the previous report's items. Change an item only when a modified file
changes it.

## Structure

Read `~/.claude/skills/review-diff/structure-diagram.md`. It says when to draw an ASCII diagram of
the modules or classes that the diff changes, and how. Draw it yourself after the findings, because
the diagram shows finding ids. Most small diffs get no diagram - then omit the section.

In re-review mode, copy the previous report's diagram. Remove the finding ids that the new report
does not have. Draw it again only when a modified file changes a module dependency or a class flow
that the diagram shows.

## Review guide

The guide tells a human reviewer which files to read first, and in which order. Write it after the
findings, because findings change the order.

Select and order the focus files with `~/.config/ai/references/review-guide.md`, section "Focus
files". A file with a `critical` or `high` finding is also a focus file, and it counts toward the
limit of 5. It goes first, together with the files that have invasive or high-risk code.

For a simple change, the guide is one line: `Simple change - no file needs special focus.`

In re-review mode, copy the previous report's guide. Remove the finding ids that the new report does
not have.

## Report file

Run the helper to get the destination path (absolute path, since skill cwd is the user's repo, not
this dir). Do not re-implement repo / author / branch resolution inline.

    path="$(~/.config/ai/bin/review-report-path.sh <log-range> [report-prefix])"

Use the `log-range` and `report-prefix` values. Omit the prefix when `report-prefix` is empty.

The helper handles: worktree-aware main-repo name (via `--git-common-dir`, so every worktree of
`foo` writes under one directory regardless of the worktree folder's own name), slugification
(including diacritic transliteration, e.g. `Józef Mąka` -> `jozef-maka`), branch-name `/`->`-`
flattening, majority-author detection (the current git user when the range has no commits), a
leading `<date>` prefix (today, ISO), and `mkdir -p` of the parent. Prints the absolute path on
stdout. A cross-day re-run gets a new dated file. A same-day re-run resolves to the identical path
and overwrites (re-runs supersede within a day).

Optional second arg `prefix` -> `<date>-<prefix>-<branch>-<author>.md` (the prefix is slugified
too).
Callers like `review-gitlab` pass `mr-<iid>` this way. Omit it for the plain
`<date>-<branch>-<author>.md` form.

Do **not** substitute `git rev-parse --show-toplevel` - that returns the worktree root and breaks
the main-repo grouping convention.

## Report structure (BLUF)

```markdown
# Review: <tip> (vs <parent>)

**TL;DR:** <1-2 sentence verdict - merge / fix-then-merge / major rework, plus the single biggest
risk, naming that risk's finding id, e.g. `C1`.>

**Counts:** <N> critical, <N> high, <N> medium, <N> low

---

- Author: <name>
- Scope: <branch | uncommitted | staged | branch + uncommitted | branch + staged | commits
  <log-range>>
- Base: <parent> (<parent-source>)
- Commits: <n> Files: <n> +<add>/-<del>
- Uncommitted: <no | yes - file1, file2>
- Generated: <ISO date>
- Convention docs consulted: <comma-separated paths | none found>

## High-impact changes

1. `<file>:<line>` - <what changes>
   Impact: <why it is hard to undo or how far it reaches, with the evidence, plus finding ids>

## Structure

```
<diagram from structure-diagram.md>

<legend line>
```

## Review guide

1. `<file>` - <why to read it, plus finding ids, e.g. "new retry logic, has `H1`">
2. `<file>` - <why>

Then: <one line for the other files, e.g. "tests for the above, 3 renames, DI wiring">

## Findings

Each finding has an id: severity letter (`C` critical, `H` high, `M` medium, `L` low) + ordinal
within its section, e.g. `C1`, `H2`. Ordinals reset per section. An omitted section does not shift
later letters (High always starts at `H1`). Callers cite these ids.

Conventions & docs findings cite the doc they derive from inline, e.g.
`(violates docs/testing.md:L20)` appended to the What/Fix text.

Simplicity findings outside the diff take the `(adjacent)` suffix in the title and sit in the
`medium` or `low` section, e.g. `**M1** \`Repo.kt:88\` - single-impl interface (adjacent)`.

### Critical

- **C1** `<file>:<line>` - <short title>
  What: <1-2 sentences> Fix: <prose, or ≤3-line snippet>

### High

- **H1** `<file>:<line>` - <short title>
  What: ... Fix: ...

### Medium

- **M1** `<file>:<line>` - <short title>

### Low

- **L1** `<file>:<line>` - <short title>

## Out of scope / mentions

Pre-existing issues noticed but not introduced by this branch - mention, don't fix.
```

Omit the High-impact changes section, the Structure section, and empty severity sections when they
have no items. Reference `file:line`, do not paste surrounding context. Snippets only when prose is
unclear.

## Final reply

A caller that invoked this skill writes its own reply with the same rules.

```markdown
<the report's TL;DR>

High-impact changes:
1. `<file>:<line>` - <what changes>

```
<the report's Structure diagrams and legend lines>
```

Review guide:
1. `<file>` - <why>
2. `<file>` - <why>

- **C1** `<file>:<line>` - <short title>
- **H1** `<file>:<line>` - <short title>
- **M1** `<file>:<line>` - <short title>
- **L1** `<file>:<line>` - <short title>

Report: `<path>`
```

- Copy the high-impact items, without their `Impact:` lines. Omit the block when the report has no
  items.
- Copy the Structure diagrams as they are. Omit the block when the report has no Structure
  section.
- Copy the guide's numbered list, or its one-line simple-change form. Omit the `Then:` line.
- List all findings, one line each.
- No counts. Add a line only when the user must act on it.

## Hard constraints

- **No edits** to source files.
- **No git mutations:** no `add`, `commit`, `amend`, `push`, `rebase`, `reset`, `checkout` of other
  refs.
- **No PR/issue interaction:** no `gh pr`, no `glab mr`, no comments.
- Only filesystem write allowed: report file and its parent dir under `~/.ai/<repo>/reviews/`.

## Red flags - stop and reconsider

- Running a diff other than the emitted `diff-command`.
- Flagging code outside audit scope under a severity bucket. Only Simplicity's adjacent radius
  reaches outside the diff. Everything else belongs in "Out of scope".
- An `(adjacent)` finding above `medium`, or one without its count as evidence.
- Reading past one hop, or widening to the module on a branch that only edits function bodies.
- Long code blocks in the report. Keep it scannable - TL;DR + Counts come first.
- Filling buckets with manufactured findings.
- A finding whose only claim is that an intended change is hard to undo or affects many places.
  That is a high-impact item.
- A high-impact item without its evidence, or one for a local, compatible, or easy-to-undo change.
- Writing a finding without confirming its `file:line` and claim against the actual diff. Unverified
  findings are fabrications - drop them.
- Dispatching review agents for a diff of 20 files or fewer, or in re-review mode. Audit it
  yourself.
- Writing a re-review report without the previous report's unresolved findings copied into it, or
  renumbering a copied id.
- Letting a review agent write the report, or dispatch its own agents.
- Copying a returned finding into the report without verifying it against the diff.
- Touching any file other than the report.
- A Structure diagram with code in it (signatures, bodies, build-file lines), or a diagram for a
  diff that changes no module dependency and no non-obvious class flow.
- Recommending an inline/simplification that loses clarity or reuse - simpler must be clearer, not
  just fewer lines.
