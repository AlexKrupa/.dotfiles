---
name: review-gitlab
description:
  Use when reviewing a GitLab merge request - by URL, MR id, branch name, or current branch.
  Produces a Markdown report combining the branch audit with MR context (description, discussions,
  labels, bot findings). Opens the MR branch in a Herdr worktree workspace. Read-only - no fixes,
  commits, or comments posted.
disable-model-invocation: true
---

# review-gitlab

Wraps `review-branch` with GitLab merge request context. Same read-only constraints. Output: one
Markdown report under `~/.ai/<repo>/reviews/<date>-mr-<iid>-<branch>-<author>.md`.

Argument hint: `[mr-url | mr-id | branch | <empty>]`. Empty means "MR for current branch". Outside
the MR's repo, only a URL works.

## When to use

- User asks to review a GitLab MR, by URL, iid, branch name, or implicitly the current branch.
- Pre-merge audit that should account for the MR description, prior discussions, and bot findings,
  not just the diff.

**Do not use** for GitHub PRs, arbitrary commit ranges, or when the user only wants the raw branch
audit with no MR context - use `review-branch` directly.

## REQUIRED SUB-SKILL

Invoke `review-branch` for the audit and report scaffolding. Pass the `target_ref` from `fetch`
(the fresh `<remote>/<target>` remote-tracking ref) as the explicit parent override (see
review-branch's "Parent override" section) - not the bare local `target_branch`, which can be stale.
Do not re-implement its git discovery, severity buckets, or finding format. After it writes the
report, augment that file with MR context (sections below).

## Prerequisites

Run `"$FMR" preflight` (bind `FMR` first, see "Helper script"). It performs all deterministic checks
in fail-fast order - `glab`/`jq` present, running in a Herdr pane, `glab` authed - and prints `ok`
or aborts with one line and a non-zero exit code. On non-zero, surface the line and stop.

`GITLAB_API_TOKEN` is not checked: it is informational only. The script's API fallback uses it when
present.

## Helper script

All deterministic GitLab fetching and JSON parsing lives in a helper script next to this file. The
worktree step uses the shared `herdr-worktree.sh` (run it with `--help` for usage). The working
directory at skill-invocation time is not the skill directory. Always invoke both scripts by
absolute path. Bind them once:

```sh
FMR=~/.claude/skills/review-gitlab/fetch-mr.sh
HWT=~/.config/ai/bin/herdr-worktree.sh
```

Do not re-derive the script's behavior inline. Subcommands:

| Call | Output |
| --- | --- |
| `"$FMR" preflight` | Prints `ok`, or aborts with one line + non-zero exit. Runs the deterministic prereq checks (see "Prerequisites"). |
| `"$FMR" resolve "<input>"` | JSON: `iid`, `project_path`, `source_branch`, `target_branch`, `web_url`, `state`, `draft`, `labels`, `author`, `pipeline_status`, `description`. Input: URL, numeric iid, branch name, or empty (= current branch). |
| `"$FMR" locate <project>` | Prints the local clone of `project`: the current repo when its remote matches, else the one match under `~/src`. |
| `"$FMR" fetch <source> <target> [project]` | Run inside the clone. Fast-forwards local `<source>` to the MR tip with no checkout (keeps unpushed local commits, aborts on divergence). Refreshes the target's remote-tracking ref (`refs/remotes/<remote>/<target>` - does not write local `<target>`). JSON: `remote`, `source_branch`, `target_branch`, `target_ref` (= `<remote>/<target>`). Picks the remote whose URL matches `project` when several exist. |
| `"$HWT" <branch> --repo <clone> --move-pane` | Opens the branch's worktree as a Herdr workspace (reuses an existing one) and moves the calling pane into it. JSON: `path`, `workspace_id`, `pane_id`, `created`, `moved`. |
| `"$FMR" discussions <iid> [project]` | JSON array of normalized threads. System-only discussions are already dropped. Fields per element: `id`, `individual_note`, `resolvable`, `resolved`, `note_count`, `authors`, `first_body` (≤280 chars), `files`. |
| `"$FMR" diff-check <iid> [target]` | Exits 0 if the local `target...HEAD` file set matches the MR's. Exits 1 with the file diff on stderr otherwise. Pass the resolved `target_branch` to skip an extra `glab mr view` round-trip. |

Exit codes: `0` ok, `1` usage/parse error, `2` not found, `3` ambiguous (multiple open MRs for the
branch, or multiple clones - script lists candidates on stderr, surface them and ask the user to
pick), `4` missing dep / auth / not in Herdr, `5` network. On any non-zero, abort with one line. Do
not retry.

`pipeline_status` is `"n/a"` when the MR has no head pipeline (draft / freshly pushed) - that is
informational, not an error.

## Workflow

1. Bind `FMR` and `HWT` (see "Helper script") and run `"$FMR" preflight`.
2. `"$FMR" resolve "<input>"` -> parse the JSON with `jq` and bind `iid`, `source_branch`,
   `target_branch`, `project_path`, etc. as shell vars (or read them on demand).
3. `"$FMR" locate "$project_path"` -> bind `clone`.
4. `cd "$clone" && "$FMR" fetch "$source_branch" "$target_branch" "$project_path"` -> parse the
   JSON. Bind `target_ref` (e.g. `origin/main`) for the parent override below.
5. `"$HWT" "$source_branch" --repo "$clone" --move-pane` -> bind `path`. Tell the user the pane is
   now in the worktree workspace at `path`.
6. Enter the worktree: when the session cwd is already `path`, skip. Otherwise call `EnterWorktree`
   with `path`. When it rejects the path (session started outside `clone`), start every later Bash
   command with `cd "$path" &&` and give file tools absolute paths under `path`.
7. Invoke `review-branch` with `$target_ref` (the fresh remote-tracking ref, not the bare local
   `target_branch`) as the parent override. Compute the report path via the helper with the iid
   prefix (see "Report"), so review-branch writes to `<date>-mr-<iid>-<branch>-<author>.md`
   directly (no rename). Read the generated report before augmenting.
8. `"$FMR" discussions "$iid" "$project_path"` -> substantive-thread judgment (next section).
9. Optional: `"$FMR" diff-check "$iid" "$target_branch"`. If it exits 1, note the drift in the
   report.
10. Augment the report (see "Report" section).
11. Reply per `review-branch` "Final reply". Add a line with the worktree `path`. Keep the worktree.
    The user removes it like any other Herdr workspace.

## Discussion filtering

The script already drops discussions whose every note is a GitLab system note (label/assignee churn,
pipeline status pings, WIP toggles). For the remaining normalized threads, include in the report
when:

- `note_count >= 2`, OR
- `resolvable == true && resolved == false`, OR
- `files` overlaps with a file flagged by the audit's findings.

Otherwise omit. For bot-authored threads (`authors` contains the SAST / coverage / CI bot), include
only when the `first_body` names a specific file/function or contains a real failure message - not
pure status pings. Summarize each kept thread in one line. Do not paste full bodies.

## Report

Path: `~/.ai/<repo>/reviews/<date>-mr-<iid>-<branch>-<author>.md`. Compute it with review-branch's
helper, passing `mr-<iid>` as the prefix. Do not slugify inline:

```sh
path="$(~/.claude/skills/review-branch/report-path.sh "$target_ref" "mr-<iid>")"
```

`<author>` is the **majority git-commit author** the helper resolves (not the GitLab MR username).
The helper does repo / author / branch slugification and diacritic transliteration. Overwrite if
exists.

Augment the base report:

1. **Header** - append MR URL, target branch, labels, state, draft flag, pipeline status.
2. **Context** (new, between header and Findings):
   - Distill the MR description in one paragraph. If empty, flag "no description provided".
   - Coverage check: does the description match what the diff actually changes? Note omissions.
3. **Findings** (from base skill) - for each finding that matches an existing discussion or bot
   note, add `(see thread by @<reviewer>)` or `(SAST flagged this)` inline after the finding's id.
4. **Discussions** (new, after Findings):
   - One bullet per substantive thread: reviewer, gist, resolution state, and your own opinion when
     the thread is unresolved or in conflict with the audit. Cite the related finding id when one
     exists.
   - One bullet per substantive bot finding.
5. **Out of scope / mentions** - unchanged from base skill.

## Hard constraints

Inherited from `review-branch` plus:

- No `glab mr approve`, `glab mr note --message`/`-m`, `glab mr update`, `glab mr merge`,
  `glab mr close`, `glab mr revoke`, or any other write subcommand.
- No API `POST`/`PUT`/`DELETE`.
- No `git push`, no commits, no amends, no rebases.
- Branch changes go through `"$FMR" fetch` (fast-forward only) and `"$HWT"` (worktree). The user's
  own checkouts keep their branch.

## Red flags - stop and reconsider

- About to invoke `review-branch` without passing the MR's `target_ref` as parent override.
  Default parent detection would pick the nearest local ancestor branch and produce wrong findings
  for stacked MRs.
- About to call `glab mr` with `-m`, `--message`, `approve`, `merge`, `update`, or `note create`.
  This skill is read-only.
- Pasting full discussion text into the report. Summarize.
- Skipping the worktree because "the diff is enough". Base skill needs the working tree to inspect
  the file context, not just patch hunks.
- About to run `git checkout`/`git switch` in the user's repo. Use the worktree from `"$HWT"`.
- Multiple open MRs for the same branch and you picked one silently. Ask the user.
- Calling `glab mr view`, `glab api .../discussions`, or `glab mr list` directly instead of going
  through `$FMR`. The script defines the JSON format. Ad-hoc calls diverge from it.
