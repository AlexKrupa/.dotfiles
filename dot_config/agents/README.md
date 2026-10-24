This directory holds AI config: agent instructions and skills.

Files here are symlinked into `~/.claude/` by `claude.sh`, so editing them changes Claude's live
behavior after a sync.

## Sync

Run `./claude.sh` to (re)create symlinks. Idempotent; safe to rerun. It prints each entry's status:
`linked` (already correct), `NEW` (just created), `local` (real file at target, left untouched), or
`removed` (stale managed link cleaned up). Rerun after adding/renaming a skill.

Mapping:

- `instructions-agents.md` -> `~/.claude/CLAUDE.md` (global instructions for every project)
- `skills/*/` -> `~/.claude/skills/`

`instructions-chat.md` is not symlinked. You paste it manually into the custom instructions of an AI
chat app.

## Third-party skills

Run `./install-skills.sh` to install third-party skills with the `skills` CLI. The script is the
list of these skills. Rerun it on a new machine.

## Layout

- `skills/<name>/SKILL.md` - one skill per folder. Claude Code finds skills only at this level, so
  skills are not grouped. A script that only one skill uses is in the folder of the skill, and
  `SKILL.md` calls it.
- `skills/<name>/evals/` - regression evals for a skill, run with headless `claude -p`. Each has a
  `README.md`.
- `bin/` - scripts that more than one skill, or a file outside `skills/`, uses. The header comment
  of each script tells what it does (see [Scripts](#scripts)). Search the skills for the script name
  to find its callers.
- `bin/repo-slug.sh` - resolves a repo to its `~/.ai/<repo-name>/` slug. `instructions-agents.md`,
  the skills, and the fish configuration use it.
- `bin/watch/` - the GitLab watch: the client `watch.sh`, the daemon `watchd.sh` (one process for
  each machine), and the check engine `watch-gitlab.sh`. `hub`, `draft-pr`, `review-pr`, and `bump`
  use it. The herdr plugin `watch` reads its event log.
- `references/` - rules that more than one skill reads by absolute path
  (`~/.config/agents/references/...`). Not symlinked.
- `references/watch/` - the watch rules. `common.md` has the shared rules, a host file
  (`gitlab.md`) has the commands of a code host, and one role file for each skill has its events
  and actions.
- `evals/` - shared eval code: `harness.py` (run, isolation, timing, common checks), `compare.py`,
  `snapshot.sh`, `fixture-lib.sh`. A run loads `instructions-agents.md`, but no auto memory,
  MCP servers, or plugins, and only the skills in the `skills` list of `evals.json` (default:
  `skill_name`).

## Scripts

Skills call the scripts in `bin/` and `skills/<name>/`. No person runs them, so they have no
`--help`, no prompts, and no color.

- The header comment is the interface. It has the `# Usage:` lines, what the script does, what it
  writes (or "Writes nothing"), the output format, and the exit codes. Agents read the header, so
  change it together with the script.
- stdout has only the result for the caller. Errors go to stderr, with the script name and the
  value that failed, for example `work-start: agent not ready in pane 3`.
- Output format: one value is one plain line, for example a path. Flat fields are `key: value`
  lines. Records are JSON, one object per line.
- Exit codes are 0 and 1. If a skill acts on a different code, add it from the shared codes: 2 not
  found, 3 ambiguous, 4 missing dependency, auth, or herdr, 5 network, 6 timeout.
- A script that rewrites commits saves a backup ref first. On a conflict or a failure, it resets to
  the backup, so it never leaves a half-done rebase.

## Tests

The scripts in `bin/` and `skills/` need bash 5 or later, for example Homebrew bash. They do not
support the macOS `/bin/bash` 3.2.

- A test file is `<script>.test.sh` next to its script. Run it with `bash <file>`.
- After a change, run only the tests of the changed scripts, with the default bash.
- Each test file uses its own temp folder. Run independent test files at the same time.
- `bin/watch/watchd.test.sh` takes about 3.5 minutes. Run it in the background.

## Editing conventions

- Skill content follows `skills/documenting/SKILL.md` (avoids AI writing tropes) and the reply
  style in `instructions-agents.md`.
- A skill's `SKILL.md` needs YAML frontmatter (`name`, `description`) for the harness to load it.
