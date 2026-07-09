---
name: doc
model: sonnet
description: Use when the user asks about design docs, progress, what's next, or wants to create, update, complete, or check status of a persistent cross-session design doc. Also triggers on mentions of "doc", "design doc", or "document" in the context of tracking work.
argument-hint: "[name|done]"
---

# Design doc

Persistent design docs that survive session boundaries. Capture decisions, notes, and context during work; serve as clean reference after completion.

**Doc = living design record** (persistent, cross-session, captures knowledge).
**Claude's plan mode = implementation detail** (ephemeral, session-scoped).

Docs live in `~/.ai/<repo-name>/docs/`, where `<repo-name>` is the *main* repo directory name (slugified). All worktrees of one repo share one doc folder. Outside any git repo, docs land in `~/.ai/_no-repo/docs/`. Subfolders starting with `_` (e.g. `_legacy/`) are ignored.

## Helpers

Two bundled scripts. Use them instead of re-implementing path / lookup logic - branch names, `$PWD`, and `basename` all break in linked worktrees.

```bash
# Path of the docs dir (handles worktrees, bare repos, submodules, non-git):
docs_dir=$(~/.claude/skills/doc/bin/docs-dir.sh)

# Path of the currently active doc, or empty:
doc=$(~/.claude/skills/doc/bin/find-active-doc.sh)

# Lookup by name (substring on filename or `title:` frontmatter):
doc=$(~/.claude/skills/doc/bin/find-active-doc.sh some-name)
```

`find-active-doc.sh` auto-detect order: branch-name file with `status: active`, else single active doc in `$docs_dir`. Multiple active docs with no branch match -> empty (ask the user).

## Frontmatter invariants

- `updated:` and `created:` are unquoted ISO dates: `2026-05-25`. Trailing comments OK (`2026-05-25 <!-- note -->`). Don't quote.
- `status: active` is the marker for in-progress docs. Completed docs omit `status` and add `completed: YYYY-MM-DD`.

## Writing style

Follow `~/.config/ai/rules/documenting.md`. One line per decision or note. Explain the choice, not the benefit. No filler, no AI writing tropes.

When a decision involved alternatives, name them inline (e.g. "Chose pull over push because backpressure", not "Use pull").

## TODO states

- `[ ]` not started
- `[-]` in progress (started, not finished)
- `[x]` done

## Routing

Arguments: $ARGUMENTS

Precedence (first token wins, no substring fallback for reserved words):

- No args -> show current doc
- First token `done` -> complete current doc. Trailing `--force` skips the open-questions refusal.
- Anything else -> treat as doc name to open/create (use `find-active-doc.sh <name>`)

A doc literally named `done` is unreachable via `/doc done` - rename or use `/doc do` etc.

## Commands

### `/doc` (no args) - show current doc

Run `find-active-doc.sh`. If it returns a path: show the doc (TODO progress, open questions, recent decisions). If empty: list all active docs in `$docs_dir`, ask which one.

### `/doc <name>` - open or create doc

Run `find-active-doc.sh <name>`. If a path returns: show it.
If no match: also check `$docs_dir` for a completed doc by the same lookup (manual `find -maxdepth 1 -name "*$name*.md"`). If a completed doc matches, show read-only - do not offer to edit or reopen.
If still no match: create a new doc.

**Creating a new doc:**

1. Ask for the goal/problem if not obvious from context
2. Generate filename: `{YYYY-MM-DD}-{descriptive-name}.md` (kebab-case), where the date is the creation date (today, ISO), so the prefix equals the `created:` frontmatter value. The branch-named auto-detect convention is likewise dated: `<date>-<branch>.md`.
3. `mkdir -p "$docs_dir"`, then create the file in `$docs_dir/` using [templates/active.md](templates/active.md) verbatim, filling in title and dates
4. TODO steps follow `[Step] -> verify: [check]` format per CLAUDE.md

### `/doc done [--force]` - complete current doc

**Refuse if work isn't done.** Run safety checks first:

1. Find the active doc with `find-active-doc.sh`. If empty, ask which doc.
2. Read `## Open questions`. If any non-blank bullets remain **and** `--force` was not passed, **refuse**: list them, tell the user to answer (move to Decisions or Notes) or re-run with `--force` to drop them. Stop.
3. Read `## Working notes`. If non-empty, dump them to chat and prompt: "Promote any of these to Decisions or Gotchas before I strip the section?" Wait for explicit ack (anything other than yes/proceed/go = stop). `--force` does NOT skip this - working notes can hide gotchas worth keeping.
4. Read unchecked / in-progress TODO items (`[ ]` / `[-]`). If any remain, ask: "Open TODO items remain. Drop them or keep doc active?" Stop unless user confirms.

Only after the above:

5. Remove `status` field from frontmatter
6. Add `completed: {today}` to frontmatter
7. Remove `## TODO`, `## Open questions`, `## Working notes` sections entirely
8. Remove dates from individual decisions (the `(YYYY-MM-DD)` suffixes)
9. Remove empty sections
10. Update `updated` timestamp

Result should read cleanly as a design reference per [templates/reference.md](templates/reference.md).

## Plan mode integration

When entering plan mode with an active doc:

1. Read the doc and present unchecked `[ ]` and in-progress `[-]` TODO steps
2. Seed the plan from those steps - they become the plan's starting structure
3. After plan execution, run `/doc-sync` to update the doc with completed steps and new decisions

If a doc exists for the current work, the plan should account for keeping it up to date.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Re-implementing active-doc lookup | Use `bin/find-active-doc.sh` |
| Inferring `$docs_dir` from `$PWD` / branch / basename | Use `bin/docs-dir.sh` - others break in worktrees |
| Creating doc for trivial single-step work | Docs are for work with decisions worth preserving |
| Forgetting `updated` timestamp on edits | Always bump on modification |
| Adding implementation details to TODO steps | Steps = what, plan mode = how |
| Wordy entries | One line per decision/note. Terse. |
| Running `/doc done` with unanswered open questions | Refuse - answer first or `--force` |
| Quoting `updated:` or `created:` dates | Unquoted ISO; trailing HTML comments fine |
| Filename date prefix not matching `created:` | Both are the creation date - keep them equal |
