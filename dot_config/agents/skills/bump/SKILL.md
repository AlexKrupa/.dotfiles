---
name: bump
description: Use when the user asks to check, fix, or make one dependency bump.
argument-hint: "<PR/MR URL | branch | commit | text>"
disable-model-invocation: true
---

# bump

This skill checks one dependency bump. If CI fails, it fixes the bump. The output is a verdict
in the reply: `safe`, `safe after fixes`, or `needs you`.

For more than one bump, run this skill for each bump, one after the other.

The helper `~/.claude/skills/bump/bump-host.sh` does all calls to the code host. Run it with no
arguments to see its subcommands. If it exits with code 4 (unsupported host), ask the user for the
PR description and the CI state.

At the start, run `~/.config/agents/bin/watch/watch.sh kind bump`. It sets the kind of work of the
herdr workspace for the sidebar. Outside herdr, it does nothing.

## Steps

1. Find the bump. `$ARGUMENTS` can be a PR or MR URL, a branch, a commit, or free text.
   - For a URL or a branch, run `bump-host.sh mr <URL or branch>`. It gives the branches and the
     description.
   - For a commit, find its branch with `git branch -a --contains <sha>`.
   - If the input names only a dependency, there is no bump branch. You make the bump in step 2.
2. Get the branch. If the current branch is the bump branch (for example, `/work` started this
   session on it), stay on it. Else, check out the bump branch in this worktree.
   If there is no bump branch, make the bump yourself:
   - If the current branch is not a new branch for this work, make a new branch from the default
     branch.
   - Find the latest version. If the package moved, find the new package.
   - Commit the bump. Do not push it and do not open a PR or MR.
3. Read the diff against the target branch. Find each dependency with its old and new versions.
4. Get the release notes for each version between the old and the new version. Use the links in
   the PR description. If there are no links, search the web. Make a list of the breaking changes,
   deprecations, and behavior changes. For each item, search the repo for the call sites that it
   affects.
5. Find issues that users reported after the release, because the release notes do not list
   them. Use the issue tracker that the project links in its README or package metadata.
   Examples: GitHub Issues (`gh search issues`), Google Issue Tracker for AndroidX, YouTrack for
   Kotlin.
   - Search only issues opened after the release date of the new version. Use a few targeted
     queries per dependency, with the new version and the APIs from the step 4 call sites. Do not
     read the full tracker.
   - Keep only behavior changes, regressions, and crashes in APIs or features that the repo uses.
     Drop feature requests, questions, and issues about other APIs.
   - If an issue is closed, keep it only when its fix is not released or is in a version newer than
     the bump target.
6. Get the test result. If you made the bump in step 2, no CI runs. Run the build and the tests
   of the affected call sites locally. Else, run `bump-host.sh ci <URL or branch> --wait` in the
   background, because it can take up to 90 minutes.
   - If CI passes, do not build locally.
   - If CI fails, run `bump-host.sh failures <pipeline_id> <project_path>`. If a job failed for a
     cause that the bump did not make (a flaky test, an infra error), retry it once with
     `bump-host.sh retry <job_id> <project_path>` and wait again. Do not fix it.
7. Fix a failure that the bump caused. Do not ask first:
   - Commit each fix as a separate commit on the bump branch.
   - If a local run of only the failed task or test is faster than CI, run it before the push.
   - If the bump branch is on the remote, push. Then wait for CI again with
     `bump-host.sh ci <URL or branch> --wait --sha <new head>`.
8. Write the report.
9. If the bump has an MR, start the watch (see "Watch").

## Report

- Verdict:
  - `safe`: CI or the local run passes, and no change from step 4 or issue from step 5 affects
    the repo.
  - `safe after fixes`: CI or the local run passes after your fixes.
  - `needs you`: CI still fails, the user did not want the fix, or a behavior change or an issue
    from step 5 affects a call site that no test covers.
- Dependency, old version, new version, and the release-notes links.
- Each change from step 4 that affects the repo, with its call sites as `path:line`.
- Issues after the release: title, URL, open or closed, the fix version, and the call sites as
  `path:line`.
- The fix commits.
- The CI result, with the pipeline URL.

## Watch

Watch the MR of the bump. Read `~/.config/agents/references/watch/common.md` and follow it, with
the role file `bump.md`.
