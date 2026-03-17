---
name: roadmap-sync
description: Use after completing implementation steps, finishing a feature, fixing a bug, or any time work is done that might correspond to a roadmap step.
---

# Roadmap sync

Check active roadmaps and update completed steps.

## Procedure

1. Read all `.md` files in `~/.config/ai/roadmaps/`
2. Filter to files with `status: active` in frontmatter
3. For each active roadmap, compare recently completed work against unchecked `[ ]` steps
4. For each step that matches completed work:
   - Mark the step `[x]`
   - Update `updated` timestamp in frontmatter to today's date
5. Notify: `Roadmap: marked '[step name]' done in {filename}. Next: '[next step name]'`
6. If all steps are now checked, suggest running `/roadmap done`
