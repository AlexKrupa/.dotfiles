---
name: debug-gitlab
description:
  Use when a GitLab pipeline, job, or merge request failed and the user wants the root cause - by
  URL, id, or implicitly the current branch. Read-only analysis; an optional fix step is gated on
  explicit user approval. Never pushes, retries, merges, or comments without consent.
disable-model-invocation: true
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

Run `./gitlab.sh check`. It runs the fail-fast chain (local checks first, network last) and
prints one line per check:

- `git-repo` - hard-fails "not in a git repo" (needed for current-branch resolution and the optional
  checkout step).
- `glab` / `jq` - hard-fail if missing (the helper uses `jq` for field projection).
- `glab-auth` - hard-fails "glab not authenticated, run `glab auth login`".
- `GITLAB_API_TOKEN: present|absent` - note only. Used by `trace`/`signals` as a `curl` fallback when
  `glab api` cannot reach the project.
- `worktree: clean|dirty` - recorded, never blocks here. Only the optional checkout and fix steps
  block on a dirty tree.

Exit code 4 = a hard prerequisite failed (see the printed line). Stop and surface it.

## Input resolution

Run `./gitlab.sh resolve <input>` (script lives next to this SKILL.md). It accepts:

- empty -> current branch's failed pipeline
- pipeline URL (`.../-/pipelines/<id>`)
- job URL (`.../-/jobs/<id>`) - walks to the parent pipeline
- MR URL (`.../-/merge_requests/<iid>`) - uses `head_pipeline`, falls back to most recent
- branch name - same as empty but for a named branch

Bare numeric ids are rejected as ambiguous; ask the user for the URL form.

Output is one JSON object:
`{project_path, pipeline_id, sha, status, ref, source_branch, target_branch, web_url, mr_iid}`.
`mr_iid` is `null` when no open MR exists for the branch. Use the fields verbatim for the report
header.

Helper exit codes the skill must handle:

- `2` not found (no pipeline / no test report / empty trace) - state the gap in the report; do not
  retry blindly.
- `3` ambiguous (>1 open MR for the same branch) - the script prints the candidates on stderr; ask
  the user to pick by iid.
- `4` missing `glab` / `jq` / auth - covered by Prerequisites.
- `5` network / API failure - retry once, then surface to the user.

## Failure signals - cheapest first

Pull signals in this order. Stop as soon as the cause is clear. Most failures do not need the raw
trace.

### 1. `failure_reason` per failing job

`./gitlab.sh failed-jobs <pipeline_id>` returns a slim array
`{id, name, stage, failure_reason, allow_failure, web_url, started_at, finished_at, duration,
verdict, action}`. The script maps `failure_reason` to `verdict`/`action` deterministically (table
below, for reference - you do not apply it by hand):

| `failure_reason`             | `verdict`        | `action`             |
| ---------------------------- | ---------------- | -------------------- |
| `script_failure`             | `needs-analysis` | `analyze`            |
| `stuck_or_timeout_failure`   | `infra-stall`    | `retry`              |
| `runner_system_failure`      | `infra`          | `retry`              |
| `job_execution_timeout`      | `hit-timeout`    | `retry-or-raise-limit` |
| `api_failure`                | `api-hiccup`     | `retry`              |
| `missing_dependency_failure` | `upstream-failed`| `fix-upstream`       |
| `scheduler_failure`          | `infra`          | `retry`              |
| `archived_failure`           | `infra`          | `retry`              |
| null / unknown               | `unknown`        | `analyze`            |

Only `verdict: needs-analysis` (and `unknown`) need step 2 / 3. Every other verdict is enough to
write the report and skip the trace.

### 2. Pipeline test report (for jobs that ran tests)

`./gitlab.sh test-failures <pipeline_id>` returns only the failed JUnit cases as
`{name, classname, file, execution_time, system_output, stack_trace}` with `system_output` and
`stack_trace` each capped at 800 chars. Structured, small, no raw log needed. Exit code `2` means
the pipeline has no test report - fall through to step 3.

### 3. Raw trace - only if 1 and 2 do not pinpoint the cause

`./gitlab.sh signals <job_id>` downloads the trace to `/tmp/gl-trace-<job_id>.log` (falls
back to `curl` with `GITLAB_API_TOKEN` if `glab api` cannot reach the project) and prints the
pinpointing slices in one shot: the trace path, `tail` (last 200), hot lines with line numbers
(error/fail/exception/fatal/panic/traceback/killed/non-zero exit, last 60), and step boundaries
(`$ <command>`, ANSI-reset aware). The full log stays on disk; only these slices enter context.

For a specific line N from the hot-line list, get surrounding context with
`sed -n '<N-15>,<N+5>p' /tmp/gl-trace-<jid>.log`.

Use `./gitlab.sh trace <job_id>` (path only, no slices) if you need the raw file for some
other reason. Never `cat` or `Read` the whole file. Never use `glab ci trace` for analysis - it
streams the full log into the conversation. Reserve `glab ci trace` for the case where the user
explicitly wants to watch a running job.

For pipelines with multiple failing jobs, fan out the per-job `gitlab.sh signals` calls in
parallel (one Bash message, multiple calls). Each trace still stays on disk; only slices enter
context.

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
