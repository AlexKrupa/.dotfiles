---
name: doc-sync
model: sonnet
description: Use after completing implementation steps, finishing a feature, fixing a bug, or any time work is done that might correspond to an active design doc.
effort: low
---

# Design doc sync

Update the active design doc after completing work.

Current branch: !`git branch --show-current`

## Procedure

1. Determine the active doc:
   - Primary: user explicitly mentioned a doc this session
   - Fallback: match current branch (above) against filenames in `~/.config/ai/docs/`
2. If no active doc found, do nothing silently. Stop here.
3. Read the active doc (must have `status: active` in frontmatter)
4. For completed work:
   - Mark matching TODO steps `[x]`
   - Add decisions made during work to `## Decisions` with today's date
   - Add noteworthy findings to `## Notes`
   - Remove answered questions from `## Open questions`, move substance to Decisions or Notes
5. Update `updated` timestamp in frontmatter
6. Notify briefly (e.g., "Doc: marked 'implement API' done, added decision about retry strategy")
7. If all TODO steps are now checked, suggest running `/doc done`
