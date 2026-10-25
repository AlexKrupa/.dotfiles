This directory contains the AI configuration: the agent instructions and the skills.

`claude.sh` makes symlinks in `~/.claude/` to the files in this directory. After a sync, a change to
these files changes the live behavior of Claude.

## Sync

Start `./claude.sh` to create the symlinks, or to create them again. You can start it again with
no risk. For each entry, it shows one of these statuses:

- `linked`: the link is already correct.
- `relinked`: the script moved a managed link to the current source.
- `NEW`: the script created the link.
- `local`: a real file is at the target. The script does not change it.
- `removed`: the script removed a stale managed link.

After you add or rename a skill, start the script again.

The script makes these links:

- `instructions-agents.md` -> `~/.claude/CLAUDE.md` (the global instructions for all projects)
- `skills/*/` -> `~/.claude/skills/`

The script does not make a symlink for `instructions-chat.md`. You paste it manually into the custom
instructions of an AI chat app.

## Third-party skills

Start `./install-skills.sh` to install the third-party skills with the `skills` CLI. The script
contains the list of these skills. On a new machine, start the script again.

## Layout

- `skills/<name>/SKILL.md` - one skill for each folder. The skills are not in groups, because
  Claude Code finds skills only at this level. If only one skill uses a script, the script is in
  the folder of that skill, and `SKILL.md` calls it.
- `skills/<name>/evals/` - the regression evals of a skill. You start them with headless
  `claude -p`. Each has a `README.md`.
- `bin/` - the scripts that two or more skills use, or that a file outside `skills/` uses. Each
  script has a header comment about what it does (see [Scripts](#scripts)). To find the callers of
  a script, search the skills for the script name.
- `bin/git-lib.sh`, `bin/gitlab-lib.sh` - the shared functions of the git scripts and of the
  GitLab scripts. The scripts source these files.
- `bin/repo-slug.sh` - gives the `~/.ai/<repo-name>/` slug of a repo. `instructions-agents.md`,
  the skills, and the fish configuration use it.
- `bin/watch/` - the GitLab watch: the client `watch.sh`, the daemon `watchd.sh` (one process for
  each machine), and the check engine `watch-gitlab.sh`. `hub`, `draft-pr`, `review-pr`, `bump`,
  and `debug-gitlab` use it. The herdr plugin `watch` reads its event log.
- `references/` - the rules that two or more skills read by absolute path
  (`~/.config/agents/references/...`). `claude.sh` does not make symlinks for them.
- `references/watch/` - the watch rules. `common.md` contains the shared rules. A host file
  (`gitlab.md`) contains the commands of a code host. Each skill has one role file with its events
  and actions.
- `evals/` - the shared eval code: `harness.py` (run, isolation, timing, common checks),
  `compare.py`, `snapshot.sh`, `fixture-lib.sh`. An eval run loads `instructions-agents.md` and
  only the skills in the `skills` list of `evals.json`. The default list is `skill_name`. The run
  does not load auto memory, MCP servers, or plugins.

## Scripts

The skills call the scripts in `bin/` and `skills/<name>/`. Because persons do not start these
scripts, the scripts have no `--help`, no prompts, and no color.

- The header comment is the interface. It contains the `# Usage:` lines, the function of the
  script, the data that it writes (or "Writes nothing"), the output format, and the exit codes.
  Agents read the header. When you change the script, also change the header.
- stdout contains only the result for the caller. The script writes errors to stderr, with the
  script name and the value that failed. For example: `work-start: agent not ready in pane 3`.
- Output format: a single value is one plain line, for example a path. Flat fields are
  `key: value` lines. Records are JSON, with one object on each line.
- The exit codes are 0 and 1. If a skill must act on a different code, use a code from the shared
  list: 2 not found, 3 ambiguous, 4 missing dependency, auth, or herdr, 5 network, 6 timeout. These
  scripts give some codes a different meaning:
  - `bin/watch/watch-gitlab.sh`: 4 network, 5 permanent error. `watchd.sh` reads these codes.
  - `bin/watch/watch.sh`: 3 a new client or session replaced this one.
  - `skills/draft-ticket/ticket-id-rename.sh`: 2 the branches are pushed, 3 the restack failed.
  - `bin/herdr-start-claude`: the exit code of herdr, 2 bad arguments.
- Before a script rewrites commits, it saves a backup ref. If a conflict or a failure occurs, the
  script resets to the backup and does not leave a partial rebase.

## Tests

The scripts in `bin/` and `skills/` need bash 5 or later, for example Homebrew bash. They do not
support the macOS `/bin/bash` 3.2.

- The test file of a script is `<script>.test.sh`, in the same folder. Start it with
  `bash <file>`.
- After a change, do only the tests of the changed scripts. Use the default bash.
- Each test file uses its own temporary folder. Start independent test files at the same time.
- The tests of `bin/watch/watchd.sh` are in 6 files, `bin/watch/watchd-<topic>.test.sh`. Their
  common setup is in `bin/watch/watchd-test-lib.sh`. Each file takes up to 1 minute. Start all 6
  at the same time, in the background.

## Editing conventions

- The content of a skill must obey `skills/documenting/SKILL.md` (rules against AI writing tropes)
  and the reply style in `instructions-agents.md`.
- The `SKILL.md` of a skill must have YAML frontmatter with `name` and `description`. Without it,
  Claude Code does not load the skill.
