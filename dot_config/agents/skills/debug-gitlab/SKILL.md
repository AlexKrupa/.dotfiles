---
name: debug-gitlab
description:
  Use when a GitLab pipeline, job, or merge request pipeline failed and the cause is not known -
  by pipeline, job, or MR URL, by branch, or on the current branch. Also use for a failed pipeline
  event during a watch.
argument-hint: "[pipeline-url | job-url | mr-url | branch | <empty>]"
allowed-tools:
  - Bash(~/.config/agents/bin/gitlab-pipeline.sh *)
  - Bash(~/.config/agents/bin/watch/watch.sh *)
---

# debug-gitlab

This skill finds the root cause of a failed GitLab pipeline, job, or merge request. It does not
change GitLab. The output is one Markdown report in the reply. If the log names a code fix, the
skill applies and commits the fix after the analysis.

An empty argument means "the failed pipeline on the current branch".

At the start, run `~/.config/agents/bin/watch/watch.sh kind debug`. It sets the kind of work of the
herdr workspace for the sidebar. Outside herdr, it does nothing.

## Prerequisites

The working directory is the user's repo, not the skill directory. Always run the helper by its
absolute path. Shell variables do not persist between Bash calls. Start each command that uses
`$GL` with the binding:

```sh
GL=~/.config/agents/bin/gitlab-pipeline.sh; "$GL" check
```

`check` runs the checks in fail-fast order: local checks first, network checks last. It prints one
line for each check:

- `git-repo` - fails with "not in a git repo". The skill needs the repo to find the current branch
  and for the optional checkout step.
- `glab` / `jq` - fails if the tool is missing. The helper uses `jq` to select JSON fields.
- `glab-auth` - fails with "glab not authenticated, run `glab auth login`".
- `GITLAB_API_TOKEN: present|absent` - a note only. `trace` and `signals` use the token for a
  `curl` fallback when `glab api` cannot get to the project.
- `worktree: clean|dirty` - a note only. Only the optional checkout and fix steps stop on a dirty
  tree.

Exit code `4` means that a prerequisite failed. Show the printed line to the user and stop.

## Input resolution

Run `"$GL" resolve <input>`. The input can be:

- empty - the failed pipeline of the current branch
- a pipeline URL (`.../-/pipelines/<id>`)
- a job URL (`.../-/jobs/<id>`) - the helper finds the parent pipeline
- an MR URL (`.../-/merge_requests/<iid>`) - the helper uses `head_pipeline`. If there is no head
  pipeline, it uses the most recent pipeline.
- a branch name - the same as empty, for the named branch

The helper rejects a bare numeric id because it is ambiguous. Ask the user for the URL.

The output is one JSON object:
`{project_path, pipeline_id, sha, status, ref, source_branch, target_branch, web_url, mr_iid}`.
`mr_iid` is `null` when the branch has no open MR. Use the field values without changes in the
report header.

Helper exit codes:

- `2` - not found: no pipeline, no test report, or an empty trace. Write in the report what is
  missing. Do not retry.
- `3` - ambiguous: more than one open MR for the branch. The helper prints the candidates on
  stderr. Ask the user to select one by iid.
- `4` - `glab`, `jq`, or auth is missing. See "Prerequisites".
- `5` - network or API failure. Retry one time. If it fails again, tell the user.

## Failure signals - cheapest first

Get the signals in this sequence. Stop when the cause is clear. Most failures do not need the raw
trace.

### 1. `failure_reason` for each failed job

`"$GL" failed-jobs <pipeline_id>` prints an array of
`{id, name, stage, failure_reason, allow_failure, web_url, started_at, finished_at, duration,
verdict, action}`. The helper sets `verdict` and `action` from `failure_reason`. The table is for
reference only. Do not apply it yourself.

| `failure_reason`             | `verdict`         | `action`               |
| ---------------------------- | ----------------- | ---------------------- |
| `script_failure`             | `needs-analysis`  | `analyze`              |
| `stuck_or_timeout_failure`   | `infra-stall`     | `retry`                |
| `runner_system_failure`      | `infra`           | `retry`                |
| `job_execution_timeout`      | `hit-timeout`     | `retry-or-raise-limit` |
| `api_failure`                | `api-hiccup`      | `retry`                |
| `missing_dependency_failure` | `upstream-failed` | `fix-upstream`         |
| `scheduler_failure`          | `infra`           | `retry`                |
| `archived_failure`           | `infra`           | `retry`                |
| null or unknown              | `unknown`         | `analyze`              |

Only the verdicts `needs-analysis` and `unknown` need step 2 or step 3. For all other verdicts,
write the report and do not get the trace.

### 2. Pipeline test report (for jobs that ran tests)

`"$GL" test-failures <pipeline_id>` prints only the failed JUnit cases as
`{name, classname, file, execution_time, system_output, stack_trace}`. `system_output` and
`stack_trace` each have a limit of 800 characters. Exit code `2` means that the pipeline has no
test report. Then go to step 3.

### 3. Raw trace - only if step 1 and step 2 do not find the cause

`"$GL" signals <job_id>` downloads the trace to `/tmp/gl-trace-<job_id>.log`. If `glab api`
cannot get to the project, it uses `curl` with `GITLAB_API_TOKEN`. Then it prints these parts of
the trace:

- the trace path
- `tail`: the last 200 lines
- hot lines with line numbers: error, fail, exception, fatal, panic, traceback, killed, non-zero
  exit. The last 60 hot lines.
- step boundaries: `$ <command>` lines, with ANSI reset codes removed

The full log stays on disk. Only these parts go into the context.

To see the lines around hot line N, run `sed -n '<N-15>,<N+5>p' /tmp/gl-trace-<job_id>.log`.

`"$GL" trace <job_id>` prints only the path, with no parts. Use it if you need the raw file for a
different reason. Never `cat` or `Read` the full file. Never use `glab ci trace` for analysis. It
puts the full log into the conversation. Use `glab ci trace` only when the user wants to watch a
running job.

If the pipeline has more than one failed job, run the `"$GL" signals` calls in parallel: one
message with one Bash call for each job.

## Classification

Give each failed job one class:

- **code** - an assertion, compile error, lint error, or test failure in a file that the branch
  changed.
- **config** - `.gitlab-ci.yml`, a Dockerfile, an image tag, a missing CI variable, or a wrong
  runner tag.
- **infra** - a runner timeout, `dial tcp`, a 5xx from a registry or dependency mirror, OOM, or a
  full disk.
- **dependency** - an upstream package is not available, lockfile drift, registry auth, or an npm
  404.
- **flaky** - use only when the log shows the symptom (a timing-dependent assertion, an
  intermittent network error), or when the same test failed one time and passed on a clean retry.
  If you are not sure, use `code` or `infra`.

Give each failed job one action: `retry`, `fix-in-repo`, `escalate`, or `wait-and-retry`.

For a job that step 1 closed without analysis, use the script `verdict`:

- `infra`, `infra-stall`, `api-hiccup` - class `infra`, action `retry`.
- `hit-timeout` - class `infra`, action `retry`. The cause tells the user to increase the job
  timeout if the retry also times out.
- `upstream-failed` - the class and the action of the failed upstream job.

## Report

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

<one short paragraph: retry command, "fix committed as <sha>", or "wait for upstream X">
````

## Optional fix flow

Use this flow only when the verdict is `fix needed in repo` and the log gives sufficient data to
name the fix. If you must examine the repo, go to "Repo-context analysis".

1. Run `git status --porcelain`. If the output is not empty, stop and tell the user. Do not stash.
2. Select the fix branch from the table below.
3. Make the edit with the edit tools, not with shell `sed`.
4. Commit the fix with a one-line conventional commit message. Use
   `git-spice commit create -m <msg> --no-prompt`.
5. If the request asks for a fix and the branch is on the remote, push. Else, do not push.
6. In the reply, give the commit SHA and the diff.

| Source branch state                                | Action                                                                                                                                  |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| The failed pipeline is on the default branch, the current branch is not the default branch, and it has no commits above the default branch | Edit in place. Do not check out a branch. The other rows and the checkout of "Repo-context analysis" do not apply. |
| Checked out, the user is the majority author       | Edit in place.                                                                                                                          |
| On `main` or the default branch                    | Create `fix/<short-cause>` from the default branch and check it out. Use `git-spice branch create <name> --target <default-branch> --no-commit --no-prompt`. Use the repo convention if `CONTRIBUTING.md` or `.gitlab/` has one. |
| Not checked out, the user is the majority author   | Check it out as in "Repo-context analysis", then edit in place.                                                                         |
| The user is not the majority author                | Refuse. Print "branch belongs to @<author>; ask before fixing" and stop.                                                                |

To find the first row, run `git rev-list --count origin/<default-branch>..HEAD`. The output `0`
means that the current branch has no commits above the default branch.

## Repo-context analysis (when the log is not sufficient)

If the failed pipeline is on the default branch, the current branch is not the default branch,
and it has no commits above the default branch, do not check out. Start at step 4
in the current worktree.

1. Run `git status --porcelain`. If the output is not empty, stop and tell the user: "uncommitted
   changes present - commit or stash and re-run". Do not stash.
2. Run `git fetch <remote> <source_branch>`, then `git checkout <source_branch>`. `<remote>` is
   `origin` by default. If there is more than one remote, use the remote of the MR's project (from
   `web_url`).
3. Tell the user that the worktree is now on the source branch.
4. Do the analysis again with file access. Examine the files that the trace names. Run the failed
   command locally if it is fast and deterministic.
5. Add a "Repo evidence" sub-bullet below the related failure in the report.

## Hard constraints

- No amends or rebases. Commit and push only as "Optional fix flow" tells. Only two checkouts are
  permitted: the source branch of the failed pipeline ("Repo-context analysis") and a new
  `fix/<short-cause>` branch ("Optional fix flow").
- No `glab ci retry`, `glab ci cancel`, `glab mr create / update / merge / approve / note`, and no
  `glab issue` write subcommands.
- No API `POST`, `PUT`, or `DELETE`.

## Red flags - stop and think again

- You are about to run `glab ci retry` because the log "looks like a flaky test". Recommend the
  retry in the report. The user runs it.
- You read a downloaded trace with `Read` or `cat`. Use `tail`, `grep`, or `sed` to get parts.
- You go to the raw trace before you check `failure_reason` and the test report. Cheap signals
  come first.
- You do not resolve the MR because the user gave a job URL. Always show the pipeline and the MR.
- You put more than about 20 lines of trace for one failure into the report.
- You push, and the request did not ask for a fix.
- You check out a branch and do not tell the user. Always tell the user and make sure that the
  worktree is clean first.
- You use `flaky` with no log evidence. If you are not sure, use `code` or `infra`.
- There is more than one open MR for the branch, and you selected one without a question. Ask.
