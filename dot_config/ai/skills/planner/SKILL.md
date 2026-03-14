---
name: planner
description: Use when the user asks about their plan, progress, what's next, or wants to create, update, or check status of a persistent cross-session plan.
---

# Planner

Persistent cross-session plans that survive session boundaries, track step completion, and serve as the
source of truth when resuming work.

**Planner = the what** (persistent, cross-session, status-tracked).
**Claude's plan mode = the how** (ephemeral, session-scoped, implementation detail).

Plans live in `~/.config/ai/plans/`.

## Commands

### `/planner` (no args) - current plan status

Auto-detect: check git branch for ticket ID, match against plan filenames.
If match: show status (completed/total, next step, remaining). If no match: list active plans, ask which.

### `/planner new` - create plan

1. Ask for goal, check git branch for ticket ID
2. Generate filename: `{ticket-id}-{descriptive-name}.md` or `{descriptive-name}.md` (kebab-case)
3. Create plan in `~/.config/ai/plans/` using the format in "Plan file format"
4. Steps follow `[Step] -> verify: [check]` format per CLAUDE.md

### `/planner list` - list all plans

Show all plans grouped by status: active first, then paused, then completed.
Include title, ticket ID (if any), progress (e.g., 3/7 steps done).

### `/planner done` - complete current plan

Set frontmatter `status: completed`, update timestamp, brief summary.

## Plan file format

```markdown
---
title: Short descriptive title
ticket: PROJ-123          # optional
status: active            # active | paused | completed
repos:                    # optional, only when multi-repo context helps
  - ~/.config/ai
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

Next step = first unchecked `[ ]` item. Use H3 phase headings only for complex multi-phase plans.

## Auto-update behavior

When you complete work that matches a plan step during normal development:

1. Mark the step `[x]` in the plan file
2. Update `updated` timestamp in frontmatter
3. Notify: `Planner: marked '[step name]' done. Next: '[next step name]'`

All other modifications (add step, reorder, pause) happen conversationally.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Creating plan for trivial single-step work | Plans are for multi-step, multi-session work |
| Forgetting to update `updated` timestamp | Always update when modifying plan |
| Adding implementation details to plan steps | Steps = what. Claude's plan mode = how. |
| Not checking for existing plan before creating | Run `/planner list` first |
