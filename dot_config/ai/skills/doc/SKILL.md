---
name: doc
model: sonnet
description: Use when the user asks about design docs, progress, what's next, or wants to create, update, complete, or check status of a persistent cross-session design doc. Also triggers on mentions of "doc", "design doc", or "document" in the context of tracking work.
argument-hint: "[name|done]"
---

# Design doc

Persistent design docs that survive session boundaries. Capture decisions, notes, and context during work;
serve as clean reference after completion.

**Doc = living design record** (persistent, cross-session, captures knowledge).
**Claude's plan mode = implementation detail** (ephemeral, session-scoped).

Docs live in `~/.ai/docs/<repo-name>/`, where `<repo-name>` is the *main* repo directory name. All worktrees of one repo share a single doc folder. Outside any git repo, docs land flat in `~/.ai/docs/`. Subfolders starting with `_` (e.g. `_legacy/`) are ignored when scanning for active docs.

### Resolving `<repo-name>`

```bash
common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$common_dir" ]; then
  docs_dir="$HOME/.ai/docs/$(basename "$(dirname "$common_dir")")"
else
  docs_dir="$HOME/.ai/docs"
fi
```

`git rev-parse --git-common-dir` returns the main repo's `.git` even from a linked worktree, so all worktrees resolve to the same `docs_dir`.

## Writing style

Follow `~/.config/ai/rules/documenting.md`. One line per decision or note. Explain the choice, not the benefit. No filler, no AI writing tropes.

When a decision involved alternatives, name them inline (e.g. "Chose pull over push because backpressure", not "Use pull").

## TODO states

- `[ ]` not started
- `[-]` in progress (started, not finished)
- `[x]` done

## Routing

Arguments: $ARGUMENTS

- No args -> show current doc
- `done` -> complete current doc
- Anything else -> treat as doc name to open/create

## Commands

### `/doc` (no args) - show current doc

Auto-detect: match git branch name against doc filenames in `$docs_dir` (see "Resolving `<repo-name>`" above).
If match found: show the doc (TODO progress, open questions, recent decisions).
If no match or not in a git repo: list all active docs, ask which one.

### `/doc <name>` - open or create doc

Look for a doc matching `<name>` in `$docs_dir` (substring match on filename or `title` frontmatter).

If match is an active doc: show it.
If match is a completed doc: show it read-only. Don't offer to edit or reopen.
If no match: create a new doc.

**Creating a new doc:**
1. Ask for the goal/problem if not obvious from context
2. Generate filename: `{descriptive-name}.md` (kebab-case)
3. `mkdir -p "$docs_dir"`, then create the file in `$docs_dir/` using the active doc format in [format-active.md](format-active.md)
4. TODO steps follow `[Step] -> verify: [check]` format per CLAUDE.md

### `/doc done` - complete current doc

Convert the active doc to the reference format in [format-reference.md](format-reference.md):
1. Remove `status` field from frontmatter
2. Add `completed: {today}` to frontmatter
3. Remove `## TODO` section entirely
4. Remove `## Open questions` section entirely
5. Remove `## Working notes` section entirely (keep `## Gotchas`)
6. Remove dates from individual decisions (the `(YYYY-MM-DD)` suffixes)
7. Remove empty sections
8. Update `updated` timestamp

Result should read cleanly as a design reference.

## Plan mode integration

When entering plan mode with an active doc:
1. Read the doc and present unchecked `[ ]` and in-progress `[-]` TODO steps
2. Seed the plan from those steps - they become the plan's starting structure
3. After plan execution, run doc-sync to update the doc with completed steps and new decisions

If a doc exists for the current work, the plan should account for keeping it up to date.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Creating doc for trivial single-step work | Docs are for work with decisions worth preserving |
| Forgetting `updated` timestamp | Always update when modifying |
| Adding implementation details to TODO steps | Steps = what, plan mode = how |
| Wordy entries | One line per decision/note. Terse. |
