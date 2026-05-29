---
name: review-gitlab
description:
  Use when reviewing a GitLab merge request - by URL, MR id, branch name, or current branch.
  Produces a Markdown report combining the branch audit with MR context (description, discussions,
  labels, bot findings). Read-only: no fixes, commits, or comments posted.
---

# review-gitlab

Wraps `review-branch` with GitLab merge request context. Same read-only constraints. Output: one
Markdown report under `~/.ai/<repo>/reviews/mr-<iid>-<branch>-<author>.md`.

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
3. `command -v glab` and `command -v jq` — abort with the missing tool name.
4. `glab auth status` — abort "glab not authenticated, run `glab auth login`".
5. `GITLAB_API_TOKEN` — note only; the script's API fallback uses it when present.

## Helper script

All deterministic GitLab fetching and JSON parsing lives in a helper script next to this file. The
working directory at skill-invocation time is the user's repo, not the skill directory, so always
invoke the script by absolute path. Bind it once:

```sh
FMR=~/.config/ai/skills/review-gitlab/fetch-mr.sh
```

Do not re-derive the script's behavior inline. Subcommands:

| Call                                 | Output                                                                                                                                                                                                               |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `"$FMR" resolve "<input>"`           | JSON: `iid`, `project_path`, `source_branch`, `target_branch`, `web_url`, `state`, `draft`, `labels`, `author`, `pipeline_status`, `description`. Input: URL, numeric iid, branch name, or empty (= current branch). |
| `"$FMR" discussions <iid> [project]` | JSON array of normalized threads. System-only discussions are already dropped. Fields per element: `id`, `individual_note`, `resolvable`, `resolved`, `note_count`, `authors`, `first_body` (≤280 chars), `files`.   |
| `"$FMR" diff-check <iid> [target]`   | Exits 0 if local `target...HEAD` file set matches the MR's; exits 1 with the file diff on stderr otherwise. Pass the resolved `target_branch` to skip an extra `glab mr view` round-trip.                            |

Exit codes: `0` ok, `1` usage/parse error, `2` not found, `3` ambiguous (multiple open MRs for the
branch — script lists candidate iids on stderr; surface them and ask the user to pick), `4` missing
dep / auth, `5` network. On any non-zero, abort with one line; do not retry.

`pipeline_status` is `"n/a"` when the MR has no head pipeline (draft / freshly pushed) — that is
informational, not an error.

## Workflow

1. Run prerequisites above and bind `FMR` as shown.
2. `"$FMR" resolve "<input>"` → parse the JSON with `jq` and bind `iid`, `source_branch`,
   `target_branch`, `project_path`, etc. as shell vars (or read them on demand).
3. `git fetch <remote> <source_branch>` then `git checkout <source_branch>`. `<remote>` defaults to
   `origin`; if multiple remotes exist, prefer the one whose URL matches `project_path`. If the user
   was on a different branch before, tell them explicitly that the worktree is now on the MR's
   source branch.
4. Ensure `<target_branch>` exists locally: `git rev-parse --verify <target_branch>` ||
   `git fetch <remote> <target_branch>:<target_branch>`.
5. Invoke `review-branch` with `<target_branch>` as the parent override. Compute the report path via
   the helper with the iid prefix (see "Report"), so review-branch writes to
   `mr-<iid>-<branch>-<author>.md` directly (no rename). Read the generated report before augmenting.
6. `"$FMR" discussions "$iid" "$project_path"` → substantive-thread judgment (next section).
7. Optional: `"$FMR" diff-check "$iid" "$target_branch"`; if it exits 1, note the drift in the
   report.
8. Augment the report (see "Report" section).

## Discussion filtering

The script already drops discussions whose every note is a GitLab system note (label/assignee churn,
pipeline status pings, WIP toggles). For the remaining normalized threads, include in the report
when:

- `note_count >= 2`, OR
- `resolvable == true && resolved == false`, OR
- `files` overlaps with a file flagged by the audit's findings.

Otherwise omit. For bot-authored threads (`authors` contains the SAST / coverage / CI bot), include
only when the `first_body` names a specific file/function or contains a real failure message — not
pure status pings. Summarize each kept thread in one line; do not paste full bodies.

## Report

Path: `~/.ai/<repo>/reviews/mr-<iid>-<branch>-<author>.md`. Compute it with review-branch's helper,
passing `mr-<iid>` as the prefix; do not slugify inline:

```sh
path="$(~/.config/ai/skills/review-branch/report-path.sh "<target_branch>" "mr-<iid>")"
```

`<author>` is the **majority git-commit author** the helper resolves (not the GitLab MR username),
and the helper owns repo / author / branch slugification and diacritic transliteration. Overwrite if
exists.

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
- Calling `glab mr view`, `glab api .../discussions`, or `glab mr list` directly instead of going
  through `$FMR`. The script owns the JSON shape; ad-hoc calls drift from it.
