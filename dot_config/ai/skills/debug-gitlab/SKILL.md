---
name: debug-gitlab
description:
  Use when a GitLab pipeline, job, or merge request failed and the user wants the root cause - by
  URL, id, or implicitly the current branch. Read-only analysis; an optional fix step is gated on
  explicit user approval. Never pushes, retries, merges, or comments without consent.
---

# debug-gitlab

Read-only root-cause analysis for a failing GitLab pipeline, job, or merge request. Output is a
single Markdown report printed to stdout. The skill may offer a code fix after analysis, but only
applies it after the user says yes, and never commits or pushes.

Argument hint: `[pipeline-url | pipeline-id | job-url | job-id | mr-url | mr-iid | <empty>]`. Empty
means "the failing pipeline on the current branch".

## When to use

- A pipeline, job, or MR failed and the user asks "why did it fail", "what's wrong with my CI",
  "debug this pipeline", "the build is red", or similar.
- Entry point is intentionally flexible: any of the inputs above, or the current branch.

**Do not use** for: green pipelines, GitHub Actions, generic "fix my code" requests unconnected to
CI, reviewing an MR before merge (use `review-gitlab`), cleaning up a branch (use `review-me`).

## Prerequisites

Fail-fast order: local checks first, network last. On any failure, print one line and stop.

1. `git rev-parse --is-inside-work-tree` - abort "not in a git repo" (needed for current-branch
   resolution and the optional checkout step).
2. `command -v glab` - abort "glab not installed".
3. `glab auth status` - abort "glab not authenticated, run `glab auth login`".
4. `GITLAB_API_TOKEN` - note presence only. Required only if `glab api` fails authentication or the
   raw `curl` fallback is needed.
5. `git status --porcelain` - record but do not block. Only blocks at the optional checkout and fix
   steps.

## Input resolution

Goal of every row: produce
`(project_path, pipeline_id, [failing_job_ids], [mr_iid], source_branch, target_branch, web_url, sha, status)`.
Prefer `glab` CLI; fall back to `glab api` (or `curl` with `GITLAB_API_TOKEN`) only when the CLI
cannot return the field.

| Input                               | Primary command                                                                                     |
| ----------------------------------- | --------------------------------------------------------------------------------------------------- |
| Empty                               | `git rev-parse --abbrev-ref HEAD` -> `glab ci get --branch <b> --output json`                       |
| Pipeline URL `.../-/pipelines/<id>` | parse `<group>/<project>` + id; `glab ci get --pipeline-id <id> -R <group>/<project> --output json` |
| Pipeline id (numeric)               | `glab ci get --pipeline-id <id> --output json`                                                      |
| Job URL `.../-/jobs/<id>`           | parse path + id; `glab api projects/<urlencoded-path>/jobs/<id>`                                    |
| Job id (numeric)                    | `glab api projects/:fullpath/jobs/<id>` (uses current repo's remote)                                |
| MR URL `.../-/merge_requests/<iid>` | `glab mr view <iid> -R <group>/<project> --output json`                                             |
| MR iid (numeric)                    | `glab mr view <iid> --output json`                                                                  |

`<urlencoded-path>` = group + `/` + project, URL-encoded (`/` -> `%2F`).

After the entry point resolves, always walk outward to the full triple:

- **Job -> pipeline:** the job JSON includes `pipeline.id`. Then run the pipeline path below.
- **Pipeline -> MR:** `glab mr list --source-branch <ref> --state opened --output json`. Zero rows =
  "no MR for branch <ref>" in the report. More than one open MR for the same branch = ask the user
  to pick by iid before proceeding.
- **Pipeline -> failing jobs:** `glab api projects/:fullpath/pipelines/<pid>/jobs?scope=failed`.
- **MR -> pipelines:** `glab api projects/:fullpath/merge_requests/<iid>/pipelines`. Pick
  `head_pipeline` first; fall back to the most recent.

Include all three (pipeline, failing jobs, MR) in the report header regardless of which one the user
passed.

## Failure signals - cheapest first

Pull signals in this order. Stop as soon as the cause is clear. Most failures do not need the raw
trace.

### 1. `failure_reason` on the job JSON

Already present in `glab api projects/:fullpath/pipelines/<pid>/jobs?scope=failed`. Known values and
what they mean for the verdict:

| `failure_reason`             | Verdict               | Action               |
| ---------------------------- | --------------------- | -------------------- |
| `script_failure`             | needs deeper analysis | go to step 2 / 3     |
| `stuck_or_timeout_failure`   | infra / runner stall  | retry                |
| `runner_system_failure`      | infra                 | retry                |
| `job_execution_timeout`      | hit the timeout       | retry or raise limit |
| `api_failure`                | GitLab API hiccup     | retry                |
| `missing_dependency_failure` | upstream stage failed | fix the upstream     |
| `scheduler_failure`          | infra                 | retry                |
| `archived_failure`           | infra                 | retry                |

For anything other than `script_failure`, this is usually enough to write the verdict and skip the
trace.

### 2. Pipeline test report (for jobs that ran tests)

`glab api projects/:fullpath/pipelines/<pid>/test_report` returns a JUnit-shaped JSON summary. Read
only the `failed` entries. Each one has the test name, file (often), and a truncated stack trace.
This is structured, small, and avoids the raw log entirely.

### 3. Raw trace - only if 1 and 2 do not pinpoint the cause

Keep the trace on disk; never pull the full file into context.

```sh
glab api projects/:fullpath/jobs/<jid>/trace > /tmp/gl-trace-<jid>.log
# fallback if glab cannot reach that project:
curl -sH "PRIVATE-TOKEN: $GITLAB_API_TOKEN" \
  "https://<host>/api/v4/projects/<urlencoded-path>/jobs/<jid>/trace" \
  > /tmp/gl-trace-<jid>.log
```

Then read only slices:

- `tail -n 200 /tmp/gl-trace-<jid>.log` - bottom of the log, where most failures land.
- `grep -nE -i '(^|\s)(error|fail(ed|ure)?|exception|fatal|panic|traceback|killed|exited with code [^0])' /tmp/gl-trace-<jid>.log | tail -n 60` -
  hot lines with line numbers.
- `sed -n '<N-15>,<N+5>p' /tmp/gl-trace-<jid>.log` - context around a specific line N.
- `grep -n '^[\x1b\[0K]*\$ ' /tmp/gl-trace-<jid>.log` - step boundaries (GitLab marks each shell
  command with `$ <command>`, sometimes preceded by an ANSI reset).

Never `cat` or `Read` the whole file. Never use `glab ci trace` for analysis - it streams the full
log into the conversation. Reserve `glab ci trace` for the case where the user explicitly wants to
watch a running job.

For pipelines with multiple failing jobs, fan out the per-job downloads in parallel (one Bash
message, multiple calls). Each trace still stays on disk; only slices enter context.

## Classification

Per failing job, label one of:

- **code** - assertion, compile error, lint, test failure tied to a file the branch touched.
- **config** - `.gitlab-ci.yml`, Dockerfile, image tag, missing CI variable, wrong runner tag.
- **infra** - runner timeout, `dial tcp`, 5xx from registry / dependency mirror, OOM, disk full.
- **dependency** - upstream package unavailable, lockfile drift, registry auth, npm 404.
- **flaky** - apply only when the log itself names the symptom (timing-dependent assertion,
  intermittent network) or the same test failed once and passed on a clean retry. When unsure,
  classify as `code` or `infra`, not `flaky`.

Pick an action: `retry`, `fix-in-repo`, `escalate`, `wait-and-retry`.

## Report (stdout)

````markdown
# GitLab failure report

**Verdict:** <one line: retry safe | fix needed in repo | infra issue, not your code | mixed>

## Context

- Project: <group/project>
- MR: !<iid> "<title>" by @<author> - <web_url> (or "no MR for branch <b>")
- Branch: <source> -> <target>
- Pipeline: #<id> <status> - <web_url>
- SHA: <short>
- Failing jobs: <n> of <total>

## Failures

### <job-name> (#<job-id>, stage: <stage>) - <web_url>

- Cause: <one sentence>
- Where: <step name or trace line N>
- Class: code | config | infra | dependency | flaky
- Action: retry | fix-in-repo | escalate | wait-and-retry
- Evidence (trace at `/tmp/gl-trace-<job-id>.log`):

  ```
  <<= up to ~20 lines of relevant trace =>>
  ```

## Suggested next step

<one short paragraph: retry command, "fix in repo - confirm to proceed", or "wait for upstream X">
````

## Optional fix flow

Run this only when the verdict is `fix needed in repo` and the log evidence is enough to name the
fix without further repo inspection. Otherwise fall through to the repo-context step below.

1. Print the proposed fix: prose summary + a minimal diff sketch. Do not edit yet.
2. Prompt the user: apply / show me first / no.
3. If approved:
   - `git status --porcelain` - if non-empty, abort and warn. Do not auto-stash.
   - Pick the fix branch (table below).
   - Apply the edit with the normal editing tools (no shell `sed`).
   - Stop. Do not run `git commit`, `git push`, `glab mr create`, or `glab ci retry`. Hand the diff
     back to the user.

| Source branch state                                | Action                                                                                                                            |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| Currently checked out, user is the majority author | edit in place                                                                                                                     |
| On `main` / default branch                         | create `fix/<short-cause>` from default (use repo convention if a `CONTRIBUTING.md` or `.gitlab/` template defines one); checkout |
| Some other branch, user not the author             | refuse; print "branch belongs to @<author>; ask before fixing"; exit                                                              |

Every fix offered by this skill is a behavior change by definition (it has to flip CI from red to
green), so always ask. The auto-apply rules from `review-me` do not apply here.

## Repo-context analysis (when the log alone is not enough)

Trigger only after the user explicitly confirms a checkout.

1. `git status --porcelain` - if non-empty, abort: "uncommitted changes present; commit or stash and
   re-run". Do not auto-stash.
2. `git fetch <remote> <source_branch>` then `git checkout <source_branch>`. `<remote>` defaults to
   `origin`; if multiple remotes exist, prefer the one matching the MR's project (parsed from
   `web_url`).
3. Tell the user explicitly that the worktree is now on the source branch.
4. Re-run analysis with file access: inspect the files referenced by the trace, run the failing
   command locally if it is cheap and deterministic.
5. Add a "Repo evidence" sub-bullet under the relevant failure in the report.

## Hard constraints

- No `git push`, commits, amends, rebases. The only allowed checkouts are the failing pipeline's
  source branch (repo-context step) and a new `fix/<short-cause>` branch (fix flow), both gated on
  explicit consent.
- No `glab ci retry`, `glab ci cancel`, `glab mr create / update / merge / approve / note`, or
  `glab issue` write subcommands.
- No API `POST` / `PUT` / `DELETE`.
- Fix edits, when applied, never followed by a commit by this skill. The user picks the commit
  message and timing.

## Red flags - stop and reconsider

- About to run `glab ci retry` because the log "looks like a flake". Recommend the retry in the
  report; let the user run it.
- Reading a downloaded trace with `Read` or `cat`. Slice with `tail` / `grep` / `sed` first.
- Skipping `failure_reason` or `test_report` and going straight to the raw trace. Cheap signals
  first.
- Skipping MR resolution because the user passed a job id. Always surface the pipeline + MR.
- Pasting more than ~20 lines of trace per failure into the report.
- Editing a file before the user confirms the fix.
- Checking out a branch silently. Always announce and verify a clean worktree first.
- Labelling something `flaky` without log evidence. Default to `code` or `infra` when unsure.
- Multiple open MRs for the same branch and you picked one silently. Ask.
