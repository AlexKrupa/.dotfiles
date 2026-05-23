---
name: review-gitlab
description:
  Use when reviewing a GitLab merge request - by URL, MR id, branch name, or current branch.
  Produces a Markdown report combining the branch audit with MR context (description, discussions,
  labels, bot findings). Read-only: no fixes, commits, or comments posted.
---

# review-gitlab

Wraps `review-branch` with GitLab merge request context. Same read-only constraints. Output: one
Markdown report under `~/.ai/reviews/<repo>/<mr-id>-<author>-<branch>.md`.

Argument hint: `[mr-url | mr-id | branch | <empty>]`. Empty means "MR for current branch".

## When to use

- User asks to review a GitLab MR, by URL, iid, branch name, or implicitly the current branch.
- Pre-merge audit that should account for the MR description, prior discussions, and bot findings,
  not just the diff.

**Do not use** for GitHub PRs, arbitrary commit ranges, or when the user only wants the raw branch
audit with no MR context — use `review-branch` directly.

## REQUIRED SUB-SKILL

Invoke `review-branch` for the audit and report scaffolding. Pass the MR's `target_branch` as the
explicit parent override (see review-branch's "Parent override" section). Do not re-implement its
git discovery, severity buckets, or finding format. After it writes the report, augment that file
with MR context (sections below).

## Prerequisites

Fail-fast order: local/cheap first, network last. On any failure, print one line and stop.

1. `git rev-parse --is-inside-work-tree` — abort "not in a git repo".
2. `git status --porcelain` — if non-empty, abort: "uncommitted changes present, commit/stash and
   re-run". Do not auto-stash.
3. `command -v glab` — abort "glab not installed".
4. `glab auth status` — abort "glab not authenticated, run `glab auth login`".
5. `GITLAB_API_TOKEN` — note only; required only if API fallback triggers.

## Local checkout (before MR fetch when possible)

| Input        | Action                                                                  |
| ------------ | ----------------------------------------------------------------------- |
| Empty        | `git rev-parse --abbrev-ref HEAD` → candidate; fetch + checkout now     |
| Branch name  | candidate = arg; fetch + checkout now                                   |
| MR id or URL | skip until MR resolution returns `source_branch`, then fetch + checkout |

Checkout steps:

1. `git fetch <remote> <candidate>` — on failure, abort with the git error verbatim.
2. `git checkout <candidate>` — on failure, abort with the git error verbatim.

`<remote>` defaults to `origin`; if multiple remotes exist, prefer the one matching the MR's project
(parsed from URL or `glab mr view`'s `web_url`).

## MR resolution

Goal:
`(project, mr_iid, source_branch, target_branch, web_url, author, labels, state, draft, pipeline_status, description)`.

| Input                                                         | Command                                                                                                     |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| URL `https://<host>/<group>/<project>/-/merge_requests/<iid>` | parse project path + iid; `glab mr view <iid> -R <group>/<project> --output json`                           |
| Numeric iid                                                   | `glab mr view <iid> --output json` (glab uses current repo's remote)                                        |
| Branch                                                        | `glab mr list --source-branch <name> --state opened --output json`; 0 → abort, >1 → ask user to pick by iid |
| Empty                                                         | resolve current branch, then branch row above                                                               |

API fallback (only when glab cannot return a field, e.g. older glab missing `head_pipeline`):

```
curl -sH "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
  "https://<host>/api/v4/projects/<urlencoded-path>/merge_requests/<iid>"
```

`<urlencoded-path>` = group + `/` + project, URL-encoded (`/` → `%2F`).

## Target branch handling

After MR resolution and source-branch checkout:

1. Ensure `<target_branch>` exists locally: `git rev-parse --verify <target_branch>` ||
   `git fetch <remote> <target_branch>:<target_branch>`.
2. Invoke `review-branch` with `<target_branch>` as the parent override.
3. Read the generated report file before augmenting.

## MR context calls

Beyond `glab mr view --output json`:

- `glab mr note list <iid>` — top-level notes.
- `glab api projects/<urlencoded-path>/merge_requests/<iid>/discussions` — threaded conversations
  including reply chains and resolution state.
- `glab mr diff <iid>` — optional sanity check that local diff matches MR's; mention any drift.

## Discussion filtering

Bot notes — include when substantive:

- CI/pipeline failure summaries (the actual failure message, not "pipeline #123 passed").
- SAST / dependency-scan / coverage-drop findings.
- Anything that names a specific file or function.

Bot notes — skip:

- Pipeline status pings, label/assignee churn, "WIP" toggles, formatter bots that already pushed
  fixes.

Human discussions — include when:

- ≥2 replies, OR unresolved, OR touches a finding the audit independently raised.

Otherwise omit. Summarize threads; do not paste full text.

## Report

Path: `~/.ai/reviews/<repo>/<mr-id>-<author>-<branch>.md`. Slugify `<repo>`, `<author>`, `<branch>`
per base skill rules; `<mr-id>` is the numeric iid. Overwrite if exists.

Augment the base report:

1. **Header** — append MR URL, target branch, labels, state, draft flag, pipeline status.
2. **Context** (new, between header and Findings):
   - Distill the MR description in one paragraph. If empty, flag "no description provided".
   - Coverage check: does the description match what the diff actually changes? Note gaps.
3. **Findings** (from base skill) — for each finding that matches an existing discussion or bot
   note, add `(see thread by @<reviewer>)` or `(SAST flagged this)` inline.
4. **Discussions** (new, after Findings):
   - One bullet per substantive thread: reviewer, gist, resolution state, and your own opinion when
     the thread is unresolved or in conflict with the audit.
   - One bullet per substantive bot finding.
5. **Out of scope / mentions** — unchanged from base skill.

## Hard constraints

Inherited from `review-branch` plus:

- No `glab mr approve`, `glab mr note --message`/`-m`, `glab mr update`, `glab mr merge`,
  `glab mr close`, `glab mr revoke`, or any other write subcommand.
- No API `POST`/`PUT`/`DELETE`.
- No `git push`, no commits, no amends, no rebases.
- Local checkout is allowed; if the user was on a different branch before the skill ran, tell them
  explicitly that the worktree is now on the MR's source branch.

## Red flags — stop and reconsider

- About to invoke `review-branch` without passing the MR's `target_branch` as parent override.
  Default parent detection would diff against `main` and produce wrong findings for stacked MRs.
- About to call `glab mr` with `-m`, `--message`, `approve`, `merge`, `update`, or `note create`.
  This skill is read-only.
- Pasting full discussion text into the report. Summarize.
- Skipping checkout because "the diff is enough". Base skill needs the working tree to inspect real
  file context, not just patch hunks.
- Multiple open MRs for the same branch and you picked one silently. Ask the user.
