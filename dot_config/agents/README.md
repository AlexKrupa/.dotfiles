# CLAUDE.md

This repo holds AI config: agent instructions, rules, and skills.

Files here are symlinked into `~/.claude/` by `claude.sh`, so editing them changes Claude's live
behavior after a sync.

## Sync

Run `./claude.sh` to (re)create symlinks. Idempotent; safe to rerun. It prints each entry's status:
`linked` (already correct), `NEW` (just created), `local` (real file at target, left untouched), or
`removed` (stale managed link cleaned up). Rerun after adding/renaming a rule or skill.

Mapping:

- `AGENTS.md` -> `~/.claude/CLAUDE.md` (global instructions for every project)
- `rules/*.md` -> `~/.claude/rules/`
- `skills/*/` -> `~/.claude/skills/`

`CHAT.md` is not symlinked - it's pasted into the Claude.ai web UI manually.

## Layout

- `rules/` - topic rules loaded as context: `code.md`, `testing.md`, `documenting.md`, `kotlin.md`,
  `gradle.md`. One concern per file, kebab-case names.
- `skills/<name>/SKILL.md` - one skill per dir. Deterministic fetching/parsing lives in sibling
  helper scripts (e.g. `docs-index.sh`) that `SKILL.md` invokes, not inline prose.
- `skills/doc/` - the `/doc` design-doc system: `bin/` helpers, `hooks/` (session-start, stop,
  precompact), `templates/`.
- `skills/draft-pr/` - writes a PR draft file for any code host. Base for platform wrappers (for
  example a GitLab `/mr` skill) that publish it.
- `bin/repo-slug.sh` - resolves a repo to its `~/.ai/<repo-name>/` work-dir slug (handles worktrees,
  submodules, bare repos; prints `_no-repo` outside git). Shared by skills and `AGENTS.md`.
- `references/` - rules that more than one skill reads by absolute path
  (`~/.config/agents/references/...`). Not symlinked.
- `bin/herdr-worktree.sh` - opens a local branch as a Herdr worktree workspace, optionally moves the
  calling pane into it. Used by `work`, not tied to it.
- `bin/fetch-gitlab-mr.sh` - resolves a GitLab MR, pipeline, or job to its branches, and
  fast-forwards a local branch to its remote. Used by `review-pr` and `work`.
- `bin/gitlab-pipeline.sh` - read-only GitLab pipeline CLI: resolves a pipeline, lists the failed
  jobs with a verdict, and prints the test failures and the trace signals of a job. `failed-logs`
  prints the signals of each failed job that needs analysis. Used by `debug-gitlab`.
- `bin/watch-gitlab.sh` - watches GitLab MRs and prints one JSON line for each new event. Without
  `--mr`, it watches for the hub. With `--mr`, it watches the MRs of a stack. With `--review` and
  one `--mr`, it watches an MR for its reviewer. Used by `hub`, `draft-pr`, and `review-pr`.
- `bin/git-interdiff.sh` - prints the content change between two MR versions (base and head of
  each). After a rebase, it compares the patches, so the changes of the target branch are not in
  the output. Used by `review-pr`.
- `bin/git-diff-context.sh` - resolves the diff to review (branch vs parent, uncommitted or staged
  changes with or without the branch, or a commit range) and prints its context. Used by `review-diff` and `deslop`.
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
- `evals/` - shared eval code: `harness.py` (run, timing, common checks), `compare.py`,
  `snapshot.sh`, `fixture-lib.sh`.

## Editing conventions

- Rule and skill content follows `rules/documenting.md` (avoids AI writing tropes) and the reply
  style in `AGENTS.md`.
- A skill's `SKILL.md` needs YAML frontmatter (`name`, `description`) for the harness to load it.
