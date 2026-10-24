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

- `skills/<name>/SKILL.md` - one skill per dir. Deterministic fetching/parsing lives in sibling
  helper scripts (e.g. `docs-index.sh`) that `SKILL.md` invokes, not inline prose.
- `skills/doc/` - the `/doc` design-doc system: `bin/` helpers, `hooks/` (session-start, stop,
  precompact), `templates/`.
- `skills/draft-pr/` - writes a PR draft file for any code host. Base for platform wrappers (for
  example a GitLab `/mr` skill) that publish it.
- `bin/repo-slug.sh` - resolves a repo to its `~/.ai/<repo-name>/` work-dir slug (handles worktrees,
  submodules, bare repos; prints `_no-repo` outside git). Shared by skills and
  `instructions-agents.md`.
- `references/` - rules that more than one skill reads by absolute path
  (`~/.config/agents/references/...`). Not symlinked.
- `references/watch/` - the watch rules of `hub`, `draft-pr`, `review-pr`, and `bump`.
  `common.md` has the shared rules, a host file (`gitlab.md`) has the commands of a code host, and
  one role file for each skill has its events and actions.
- `bin/herdr-worktree.sh` - opens a local branch as a Herdr worktree workspace, optionally moves the
  calling pane into it. Used by `work`, not tied to it.
- `bin/fetch-gitlab-mr.sh` - resolves a GitLab MR, pipeline, or job to its branches, and
  fast-forwards a local branch to its remote. Used by `review-pr` and `work`.
- `bin/gitlab-pipeline.sh` - read-only GitLab pipeline CLI: resolves a pipeline, lists the failed
  jobs with a verdict, and prints the test failures and the trace signals of a job. `failed-logs`
  prints the signals of each failed job that needs analysis. Used by `debug-gitlab`.
- `bin/watch.sh` - the watch client: the background task of a session. It waits for the GitLab
  events of its subscription and prints one JSON line for each event. Without `--mr`, it watches
  for the hub. With `--mr`, it watches the MRs of a stack. With `--review` and one `--mr`, it
  watches an MR for its reviewer. If no daemon runs, it starts `bin/watchd.sh`. Used by `hub`,
  `draft-pr`, `review-pr`, and `bump`.
- `bin/watchd.sh` - the watch daemon: one process for each machine. It polls each repo with a live
  subscription and routes the events to the subscriptions.
- `bin/watch-gitlab.sh` - the check engine of the daemon: one check of the project or of the MRs,
  with the events on stdout. Its header has the list of events.
- `bin/git-interdiff.sh` - prints the content change between two MR versions (base and head of
  each). After a rebase, it compares the patches, so the changes of the target branch are not in the
  output. Used by `review-pr`.
- `bin/git-diff-context.sh` - resolves the diff to review (branch vs parent, uncommitted or staged
  changes with or without the branch, or a commit range) and prints its context. Used by
  `review-diff` and `deslop`.
- `bin/review-report-path.sh` - prints the review report path under `~/.ai/<repo-name>/reviews/`.
  Used by `review-diff` and `review-pr`.
- `bin/ticket-path.sh` - prints the ticket file path under `~/.ai/<repo-name>/tickets/`. Used by
  `draft-ticket`.
- `bin/ticket-id-rename.sh` - puts the real ticket id in place of the placeholder id: git-spice
  branch names, commit messages, added lines, remote branches, the herdr workspace, and the Claude
  session. Used by `draft-ticket`.
- `bin/pr-path.sh` - prints the PR draft path and media dir under `~/.ai/<repo-name>/prs/`. Used by
  `draft-pr`.
- `bin/git-absorb-fixes.sh` - folds file fixes into the commits that added the lines. Used by
  `review-me` and `deslop`.
- `bin/git-squash-fixups.sh` - squashes repair commits and `fixup!`/`amend!` commits into their
  targets, with a backup ref. Used by `review-me` and `draft-pr`.
- `skills/<name>/evals/` - regression evals for a skill, run with headless `claude -p`. Each has a
  `README.md`.
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
- `bin/watchd.test.sh` takes about 3.5 minutes. Run it in the background.

## Editing conventions

- Skill content follows `skills/documenting/SKILL.md` (avoids AI writing tropes) and the reply
  style in `instructions-agents.md`.
- A skill's `SKILL.md` needs YAML frontmatter (`name`, `description`) for the harness to load it.
