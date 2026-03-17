---
name: roadmap
description: Use when the user asks about their roadmap, progress, what's next, or wants to create, update, or check status of a persistent cross-session roadmap.
---

# Roadmap

Persistent cross-session roadmaps that survive session boundaries, track step completion, and serve as the
source of truth when resuming work.

**Roadmap = the what** (persistent, cross-session, status-tracked).
**Claude's plan mode = the how** (ephemeral, session-scoped, implementation detail).

Roadmaps live in `~/.config/ai/roadmaps/`.

## Commands

### `/roadmap` (no args) - current roadmap status

Auto-detect: check git branch for ticket ID, match against `ticket`, `branches`, and roadmap filenames.
If match: show status (completed/total, next step, remaining). If no match: list active roadmaps, ask which.

### `/roadmap new` - create roadmap

1. Ask for goal, check git branch for ticket ID
2. Generate filename: `{TICKET-ID}-{descriptive-name}.md` or `{descriptive-name}.md`
   Ticket portion stays uppercase, rest is kebab-case (overrides global lowercase convention for ticket prefixes).
   Example: `PLAT-123-my-feature.md`
3. Create roadmap in `~/.config/ai/roadmaps/` using the format in "Roadmap file format"
4. Steps follow `[Step] -> verify: [check]` format per CLAUDE.md

### `/roadmap list` - list all roadmaps

Show all roadmaps grouped by status: active first, then paused, then completed.
Include title, ticket ID (if any), progress (e.g., 3/7 steps done).

### `/roadmap done` - complete current roadmap

Set frontmatter `status: completed`, update timestamp, brief summary.

## Roadmap file format

```markdown
---
title: Short descriptive title
ticket: PROJ-123          # optional
status: active            # active | paused | completed
repos:                    # optional, only when multi-repo context helps
  - ~/.config/ai
branches:                 # optional, stable identifier for worktree workflows
  - feature/PROJ-123-my-feature
created: 2026-03-14
updated: 2026-03-14       # refresh on every modification
---

## Context
Why this work exists and key constraints.

## Steps
- [x] Completed step description -> verify: `gradle test` passes, new test covers edge case
- [ ] Next step description -> verify: `curl -s localhost:8080/api/health` returns 200

## Decisions
- Decision made and why (date)

## Notes
- Anything useful that doesn't fit above
```

Next step = first unchecked `[ ]` item. Use H3 phase headings only for complex multi-phase roadmaps.

## Auto-update behavior

When you complete work that matches a roadmap step during normal development:

1. Mark the step `[x]` in the roadmap file
2. Update `updated` timestamp in frontmatter
3. Notify: `Roadmap: marked '[step name]' done. Next: '[next step name]'`

All other modifications (add step, reorder, pause) happen conversationally.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Creating roadmap for trivial single-step work | Roadmaps are for multi-step, multi-session work |
| Forgetting to update `updated` timestamp | Always update when modifying roadmap |
| Adding implementation details to roadmap steps | Steps = what. Claude's plan mode = how. |
| Not checking for existing roadmap before creating | Run `/roadmap list` first |
