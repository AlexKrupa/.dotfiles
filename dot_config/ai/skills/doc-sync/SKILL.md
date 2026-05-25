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

1. Find the active doc. Use the bundled helper - do not infer from `$PWD`, branch, or basename (those break in linked worktrees):

   ```bash
   doc=$(bash ~/.config/ai/skills/doc/bin/find-active-doc.sh)
   ```

   If the user explicitly named a doc this session, prefer it:

   ```bash
   doc=$(bash ~/.config/ai/skills/doc/bin/find-active-doc.sh "<name>")
   ```

2. If `$doc` is empty, do nothing silently. Stop.

3. Read the doc.

4. For completed work, update sections **idempotently** - skip entries that already exist:

   - Mark finished TODO steps `[x]`. In-progress steps `[-]`.
   - **Decisions:** for each new decision, case-insensitive substring check against existing `## Decisions` bullets. Skip dupes. Append survivors with today's date. A decision is a choice between alternatives that someone resuming this work would want to know. Implementation details obvious from the code don't qualify.
   - **Notes:** same dedupe rule against `## Notes`. Append survivors (no date needed).
   - **Open questions:** remove answered ones; move substance to Decisions or Notes (subject to dedupe). Leave still-open questions alone.

5. Update `updated:` timestamp in frontmatter to today (unquoted ISO).

6. Notify briefly. Example: `Doc: marked 'implement API' done, added decision about retry strategy. 1 duplicate skipped.`

7. If all TODO steps are now `[x]` and `## Open questions` is empty, suggest `/doc done`.

## Common mistakes

| Mistake | Fix |
|---------|-----|
| Re-running creates duplicate decisions | Substring-dedupe before append |
| Re-implementing find-active-doc | Use `bin/find-active-doc.sh` |
| Recording obvious implementation details as decisions | Only choices between alternatives |
| Promoting open questions that weren't actually answered | Leave them; the user resolves |
| Quoting the `updated:` date | Unquoted ISO `YYYY-MM-DD` |
