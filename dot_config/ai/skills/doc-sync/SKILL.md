---
name: doc-sync
model: sonnet
description: Use after completing implementation steps, finishing a feature, fixing a bug, or any time work is done that might correspond to an active design doc.
effort: low
---

# Design doc sync

Update the active design doc after completing work.

Follow `~/.config/ai/rules/documenting.md`. One line per entry. Terse.

Current branch: !`git branch --show-current`

## Procedure

1. Determine the active doc:
   - Primary: user explicitly mentioned a doc this session
   - Fallback: match current branch (above) against filenames in `~/.config/ai/docs/`
   - If not in a git repo or no branch match: check all docs in `~/.config/ai/docs/` for `status: active`
2. If no active doc found, do nothing silently. Stop here.
3. Read the active doc (must have `status: active` in frontmatter)
4. For completed work:
   - Mark finished TODO steps `[x]`
   - Mark partially done TODO steps `[-]` (started but not finished)
   - Add decisions to `## Decisions` with today's date. A decision is a choice between alternatives that someone resuming this work would want to know. Implementation details obvious from the code don't qualify.
   - Add noteworthy findings to `## Notes`
   - Remove answered questions from `## Open questions`, move substance to Decisions or Notes
5. Update `updated` timestamp in frontmatter
6. Notify briefly (e.g., "Doc: marked 'implement API' done, added decision about retry strategy")
7. If all TODO steps are now `[x]`, suggest running `/doc done`
