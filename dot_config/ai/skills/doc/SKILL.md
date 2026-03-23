---
name: doc
description: Use when the user asks about design docs, progress, what's next, or wants to create, update, complete, or check status of a persistent cross-session design doc.
---

# Design doc

Persistent design docs that survive session boundaries. Capture decisions, notes, and context during work;
serve as clean reference after completion.

**Doc = living design record** (persistent, cross-session, captures knowledge).
**Claude's plan mode = implementation detail** (ephemeral, session-scoped).

Docs live in `~/.config/ai/docs/`.

## Commands

### `/doc` (no args) - show current doc

Auto-detect: match git branch name against doc filenames in `~/.config/ai/docs/`.
If match found: show the doc (TODO progress, open questions, recent decisions).
If no match: list active docs, ask which one.

### `/doc <name>` - open or create doc

Look for a doc matching `<name>` in `~/.config/ai/docs/` (fuzzy match on filename or title).
If found: show it.
If not found: create a new doc.

**Creating a new doc:**
1. Ask for the goal/problem if not obvious from context
2. Generate filename: `{descriptive-name}.md` (kebab-case)
3. Create in `~/.config/ai/docs/` using the active doc format below
4. TODO steps follow `[Step] -> verify: [check]` format per CLAUDE.md

### `/doc done` - complete current doc

Convert the active doc to reference format:
1. Remove `status` field from frontmatter
2. Add `completed: {today}` to frontmatter
3. Remove `## TODO` section entirely
4. Remove `## Open questions` section entirely
5. Remove dates from individual decisions (the `(YYYY-MM-DD)` suffixes)
6. Remove empty sections
7. Update `updated` timestamp

Result should read cleanly as a design reference.

## Doc format (active)

```markdown
---
title: Short descriptive title
status: active
created: YYYY-MM-DD
updated: YYYY-MM-DD
---

## Context
Why this change exists. The problem, constraints, intended outcome.

## Decisions
- Use X instead of Y because [reason] (YYYY-MM-DD)

## Notes
- Discovered that Z behaves unexpectedly when...

## Open questions
- Should we support case X?

## TODO
- [x] Completed step -> verify: unit tests pass
- [ ] Next step -> verify: check description
```

## Doc format (reference, after `/doc done`)

```markdown
---
title: Short descriptive title
created: YYYY-MM-DD
completed: YYYY-MM-DD
---

## Context
Why this change exists.

## Decisions
- Use X instead of Y because [reason]

## Notes
- Key findings, gotchas, things worth remembering
```

## Auto-update behavior

When you complete work that relates to the active doc during normal development:

1. Mark matching TODO steps `[x]`
2. Add decisions made to `## Decisions` with today's date
3. Add noteworthy findings to `## Notes`
4. Resolve open questions (move answers to Decisions or Notes, remove from Open questions)
5. Update `updated` timestamp in frontmatter
6. Notify briefly: what was updated

## Plan mode integration

When entering plan mode with an active doc, seed the plan from the doc's unchecked TODO steps.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Creating doc for trivial single-step work | Docs are for work with decisions worth preserving |
| Forgetting `updated` timestamp | Always update when modifying |
| Adding implementation details to TODO steps | Steps = what, plan mode = how |
