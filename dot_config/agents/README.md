This directory contains the AI configuration: the agent instructions and the skills.

`integrations/claude-code/install.sh` makes symlinks in `~/.claude/` to the files in this directory.
After a sync, a change to these files changes the live behavior of Claude Code.

## Sync

Start `integrations/claude-code/install.sh` to create the symlinks, or to create them again. You
can start it again with no risk. If an integration file or the set of skill folders changes,
`chezmoi apply` runs each `integrations/*/install.sh`. For each entry, the script shows one of
these statuses:

- `linked`: the link is already correct.
- `relinked`: the script moved a managed link to the current source.
- `NEW`: the script created the link.
- `local`: a real file is at the target. The script does not change it.
- `removed`: the script removed a stale managed link.

After you add or rename a skill, start the script again.

The script makes these links:

- `integrations/claude-code/CLAUDE.md` -> `~/.claude/CLAUDE.md`. This file imports
  `instructions-agents.md`, the global instructions for all projects.
- `skills/*/` -> `~/.claude/skills/`

The script does not make a symlink for `instructions-chat.md`. You paste it manually into the custom
instructions of an AI chat app.

## Third-party skills

`install-skills.sh <agent>` installs the third-party skills for one agent with the `skills` CLI.
The script contains the list of these skills. When the list or the set of folders in
`integrations/` changes, `chezmoi apply` runs it one time for each folder in `integrations/`. The
folder name is the `skills` CLI agent name. The first apply on a new machine also runs it.

## Layout

The core is `instructions-agents.md`, `skills/`, `references/`, `bin/`, and `install-skills.sh`. It
has no agent-specific text, except the evals and `mine-claude-sessions`. A new agent is one new
folder in `integrations/`.

- `integrations/claude-code/` - the Claude Code integration: the installer `install.sh` and
  `CLAUDE.md`, the Claude notes for the skills.
- `integrations/<agent>/agent.sh` - the runtime adapter. In the core, it is the only place with the
  commands and flags of an agent. The sandbox start command `herdr-start-*` of the integration and
  the daemon also have them.
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
- `bin/agent-lib.sh` - finds the herdr agent kind of a pane and the `agent.sh` adapter of that
  kind. The scripts that send agent actions source it.
- `bin/repo-slug.sh` - gives the `~/.ai/<repo-name>/` slug of a repo. `instructions-agents.md`,
  the skills, and the fish configuration use it.
- `daemon/` - the GitLab watch: one Rust program, `watchd`, with the daemon (one process for each
  machine), the check engine, and the client commands. `daemon/build.sh` builds it and installs it
  to `~/.local/bin/watchd`. `hub`, `draft-pr`, `review-pr`, `bump`, and `debug-gitlab` use it. The
  herdr plugin `watch` reads its event log with `watchd follow`.
- `bin/watch/watch-lib.sh` - the sleep, wake, and network rules of `skills/hub/hub-retry.sh`.
- `references/` - the rules that two or more skills read by absolute path
  (`~/.config/agents/references/...`). The installers do not make symlinks for them.
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
  - `watchd engine`: 4 network, 5 permanent error.
  - `skills/draft-ticket/ticket-id-rename.sh`: 2 the branches are pushed, 3 the restack failed.
  - `integrations/claude-code/herdr-start-claude`: the exit code of herdr, 2 bad arguments.
  - `integrations/claude-code/agent.sh`: 2 usage error, 3 the agent has no such action.
  - `install-skills.sh`: 2 no agent name.
  - `daemon/integrations/claude-code/wait.sh`: 2 wake Claude (the `asyncRewake` code).
- Before a script rewrites commits, it saves a backup ref. If a conflict or a failure occurs, the
  script resets to the backup and does not leave a partial rebase.

## Tests

The scripts in `bin/` and `skills/` need bash 5 or later, for example Homebrew bash. They do not
support the macOS `/bin/bash` 3.2.

- The test file of a script is `<script>.test.sh`, in the same folder. Start it with
  `bash <file>`.
- After a change, do only the tests of the changed scripts. Use the default bash.
- Each test file uses its own temporary folder. Start independent test files at the same time.
- The tests of `watchd` are `cargo` tests: the unit tests in `daemon/src/`, the engine and daemon
  tests in `daemon/tests/`. Start them with `daemon/test.sh`, which starts all test binaries at the
  same time and takes about 45 seconds. A test binary starts one test daemon at a time.

## Editing conventions

- The content of a skill must obey `skills/documenting/SKILL.md` (rules against AI writing tropes)
  and the reply style in `instructions-agents.md`.
- The `SKILL.md` of a skill must have YAML frontmatter with `name` and `description`. Without it,
  Claude Code does not load the skill.
