# Deprecated: `/doc` and `/doc-sync`

## Why deprecated

Superpowers covers complex, multi-step work better (brainstorming, plans, specs, review
checkpoints). The persistent design-doc system these skills implement is unnecessary overhead for
simple tasks, and its three hooks nagged about active docs on every session-start, stop, and
precompact. Both skills were moved out of `skills/` so the harness stops loading them and the hooks
stop running.

## What these skills did

- `/doc` - create, show, and complete persistent cross-session design docs under
  `~/.ai/<repo>/docs/`. See `SKILL.md` for the full command set and doc format.
- `/doc-sync` - idempotently update the active design doc after completing a unit of work. See
  `../doc-sync/SKILL.md`.

Shared infrastructure lives under this `doc/` tree: `bin/` (`find-active-doc.sh`, `docs-dir.sh`),
`hooks/` (`session-start.sh`, `stop.sh`, `precompact.sh`, `_common.sh`), and `templates/`.
`doc-sync` calls `doc/bin/find-active-doc.sh`, so the two move as a unit.

## Removed `AGENTS.md` instructions

The `## ~/.ai/ work directory` section is shared with Superpowers and stayed, minus the `/doc`
parts. Removed verbatim:

- From the intro line: "Shared by the `/doc` skill and" (the section is now owned by Superpowers
  only).
- The `docs/` layout bullet:

  ```
  - `docs/` - design docs, via `/doc` commands (`YYYY-MM-DD-<name>.md`)
  ```

- The closing usage paragraph:

  ```
  Design docs: non-trivial work (anything worth a plan) should have one. Suggest `/doc <name>` before
  planning; run `/doc-sync` after completing a step.
  ```

## Re-enable

1. Move both dirs back to `skills/`:

   ```bash
   mv skills/deprecated/doc skills/deprecated/doc-sync skills/
   ```

2. Rerun the sync to recreate the symlinks:

   ```bash
   ./claude.sh
   ```

   `unlink_deprecated` becomes a no-op (nothing under `skills/deprecated/`) and `link_entries`
   relinks `skills/doc` and `skills/doc-sync`.

3. Re-add the two permission entries to `~/.claude/settings.json` under `permissions.allow`:

   ```json
   "Bash(~/.claude/skills/doc/bin/find-active-doc.sh:*)",
   "Bash(~/.claude/skills/doc/bin/docs-dir.sh:*)",
   ```

4. Re-add the three hook blocks to `~/.claude/settings.json` under `hooks` (alongside the existing
   `PreToolUse` block):

   ```json
   "SessionStart": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "~/.config/ai/skills/doc/hooks/session-start.sh"
         }
       ]
     }
   ],
   "Stop": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "~/.config/ai/skills/doc/hooks/stop.sh"
         }
       ]
     }
   ],
   "PreCompact": [
     {
       "hooks": [
         {
           "type": "command",
           "command": "~/.config/ai/skills/doc/hooks/precompact.sh"
         }
       ]
     }
   ]
   ```

5. Optionally restore the removed `AGENTS.md` instructions above if you want the `docs/` convention
   and the plan-time `/doc` prompts back.
