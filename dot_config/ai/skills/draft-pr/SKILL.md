---
name: draft-pr
description:
  Writes one pull request or merge request draft (title, description, metadata, review comments)
  as a Markdown file under ~/.ai/<repo>/prs/, for any code host. After a wrapper skill publishes
  it, watches the PRs or MRs of the stack. If the user calls /draft-pr, or if the instructions of
  another skill tell you to run draft-pr, run it. Do not run it for other requests about pull
  requests or merge requests.
argument-hint: "[draft] [notes]"
---

# draft-pr

Writes one PR draft as a Markdown file: metadata, title, description, and review comments. A person
or a wrapper skill (for example a GitLab `/mr` skill) reads the file and publishes it. This skill
does not know the code host. It does not publish. After the wrapper publishes, the wrapper tells
this skill to watch the MRs (see "Watch"). During the watch, only trivial fixes are pushed.

Before it writes, it prepares the branch: it syncs and restacks with git-spice, and it squashes
repair commits. The reviewer gets a clean branch and a description that agrees with it.

The goal is a PR that reviewers want to review. Give them all relevant facts and no wall of text.

## Arguments

- `draft`: write `draft: true` in the metadata. Without it, write `draft: false`.
- All other text is notes from the user: how they tested, links, questions for reviewers.

## Workflow

### 1. Preflight

```sh
git status --porcelain
git branch --show-current
```

Stop with one line when:

- the directory is not in a git repo
- the working tree has changes, also untracked files. Name the paths. Do not stash, because a
  stash can hide work.
- there is no current branch (detached HEAD), or the branch is mainline: `main`, `master`,
  `develop`, or the git-spice trunk

The git-spice trunk is the `trunk` field of `git show refs/spice/data:repo`. If
`git rev-parse --verify -q refs/spice/data` succeeds, read it. Else skip it. Do not run a
`git-spice` command for it.

### 2. Branch preparation

Give each `git-spice` command `--no-prompt`, after the subcommand. A prompt stops a session that
has no terminal. The flag after the subcommand keeps the command in the form of the permission
rules, for example `git-spice log:*`.

```sh
git rev-parse --verify -q refs/spice/data && git-spice log short --json --no-prompt
```

Check `refs/spice/data` first. In a repo with no git-spice data, `git-spice log short` initializes
git-spice, and that changes a repo that does not use it.

If `refs/spice/data` does not exist, or the command fails, skip the git-spice commands in this step
and in step 3. Tell it in the 🧹 line of the reply.

If no output object has `"name"` equal to the current branch, git-spice does not track the branch.
Run:

```sh
git-spice downstack track --no-prompt
```

It tracks the current branch and each untracked branch below it, down to trunk or to a tracked
branch. `branch track` is not sufficient: it gives the base of the nearest tracked branch, and in a
stack with no tracked branch that base is trunk. Name each tracked branch and its base in the 🧹
line. If the command fails, skip the git-spice commands as above.

Then run:

```sh
git-spice repo sync --no-prompt
git-spice stack restack --no-prompt
```

`repo sync` pulls mainline and deletes the local branches whose PRs are merged. If it fails, for
example with no network, continue, and tell it in the 🧹 line. `stack restack` rebases each branch
of the stack on its base. For a branch with no stack, it rebases only that branch. If it fails, for
example on a conflict, stop. Show its output. Do not resolve the conflict.

Then run `git-spice log short --json --no-prompt` again. `repo sync` can delete the lower branch
and move the current branch onto mainline. Then the first output is out of date.

### 3. Commit cleanup

A PR branch is always clean. Do this step and do not ask the user first.

1. Run `~/.config/ai/bin/git-diff-context.sh` and get `parent` from its output.
2. Read `~/.config/ai/references/commit-history.md` and apply its rules to `<parent>..HEAD`.
3. If the rules flag commits, or a subject in the range starts with `fixup!` or `amend!`, run the
   script with the merge base, not with `parent`. When step 2 did not run, `parent` can be a newer
   `origin/main`, and the script then rebases the branch onto it:

   ```sh
   ~/.config/ai/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)" [<repair>:<target>...]
   ```

   Give one `<repair>:<target>` for each flagged commit. The script also squashes all `fixup!` and
   `amend!` commits. If it exits non-zero, stop. Show its output and the backup ref. A `fixup!`
   commit whose target is below `parent` stays. Name it in the 🧹 line.
4. If the script changed commits, and the object of the current branch in the second
   `log short --json` output has `ups`, run `git-spice upstack restack --no-prompt`. Else the
   branches above stay on the old commits.

### 4. Analysis

If step 3 changed commits, run `git-diff-context.sh` again. Then read:

- the commit log and the output of the emitted `diff-command`
- the conversation and the notes from the arguments
- the sources that the user points to: a ticket, a plan, a spec, a URL
- if the diff alone does not explain a change, the code around the diff

Read enough to find the changes, the high-impact changes, the focus files, and the code for review
comments. Do not look for defects. That is the job of `review-diff`.

### 5. Local conventions

If a calling skill tells you to ignore the local conventions, skip this step.

- PR template: `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/`, or
  `.gitlab/merge_request_templates/`. If one exists, use its sections in place of the sections in
  "Description", and fill them with the content rules of this skill.
- Title convention: `CONTRIBUTING.md`, and the last 20 subjects on mainline
  (`git log --first-parent --format=%s -20 <mainline>`). If they show a pattern, for example a
  ticket prefix or a type prefix, use it.

### 6. Write the file

```sh
~/.config/ai/bin/pr-path.sh
```

It prints `file=<path>` and `media=<dir>`. Write the draft to `file`. If the file exists, edit it.
Put media files in `media`. If there are media files, create that directory.

### 7. Reply

See "Reply".

## File format

```markdown
---
type: fix
draft: false
base: main
ticket: ABC-123
breaking: false
---

# Fix crash when the user rotates the note editor

## Context

[ABC-123: App closes on rotation in the note editor](https://example.com/ABC-123)

The editor keeps the note text in a field that the system clears on rotation.

## Changes

The editor keeps the note text in saved state. A rotation keeps the text.

## Testing

- New unit test for the saved state.
- Rotated the editor on an emulator with a long note.

---

# Review comments

## `app/src/main/kotlin/notes/editor/NoteEditor.kt:42`

Start here. This is the core change.
```

- The first H1 is the title. The description is all text between the title and
  `# Review comments`. A wrapper splits the file on the `# Review comments` heading.
- The `---` line before `# Review comments` is only a visual marker. Put an empty line above it.
  Without the empty line, Markdown makes the previous paragraph a heading.
- When there are no review comments, omit the `---` line and the `# Review comments` part.

Metadata fields. The wrapper uses them to select the labels of its platform.

- `type`: one of `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `build`, `perf`.
- `draft`: from the arguments.
- `base`: the `parent` of the last `git-diff-context.sh` run, with no remote prefix (`origin/main`
  is `main`). The script reads the stack parent from git-spice after the sync.
- `ticket`: the ticket id. If there is no ticket, omit the field.
- `breaking`: `true` only for a contract break or a one-way door from "High-impact changes".

## Content rules

### General

- Write in English, in ASD-STE100 Simplified Technical English.
- Use short paragraphs. Write each paragraph or list item on one line, with no hard line breaks.
  Code hosts show a line break in a paragraph as a new line.
- Use a list for separate, parallel items: links, files, test steps, independent changes. If the
  sentences explain one idea, for example a cause and its result, or steps of one flow, use a
  paragraph.
- A section with only one item has no list. Write
  `On an emulator, a search for "milk" finds the note.`, not
  `- On an emulator, a search for "milk" finds the note.` This applies to each section, also
  Testing and Out of scope.
- Write only what the sources state. A small change gives a short description.
- When an optional section has no content, do not write it. No "None" or "N/A".
- Each link has text, for example `[ABC-123: Ticket title](url)`. Never a bare URL.

### Title

- Tell what changes, not how: "Change foo to get bar", "Fix the foo crash on rotation".
- If the change is an implementation detail, for example build or infrastructure work, use
  implementation words. Else do not use them.
- Approximately 72 characters or less. No prefix, unless the local convention has one.

### Description

Sections, in this order:

1. **Context** (required): why the change is necessary, in 1-3 sentences. Links to what caused
   the change: the ticket, an issue, a design (for example Figma). Put one link above the text. Put
   two or more links in a list above the text.
2. **Changes** (required): what changes in behavior, UX, API, and data, at a high level. Add only
   the implementation details that have high impact. Put links that helped to make the change
   (external docs, internal docs, API reference) inline, next to the change that they explain.
   - `### High-impact changes` (optional) at the end of Changes. Use the criteria in
     `~/.config/ai/references/review-guide.md`, section "High-impact changes". Most PRs have none.
3. **How to review** (optional): if the diff is not a simple change, write this section. Use the
   focus files and their order from `~/.config/ai/references/review-guide.md`, section "Focus
   files". If there are 2 or more commits and each commit has value by itself, recommend a review
   commit by commit.
4. **Testing**: the automated tests from the diff, and the manual testing from the conversation
   or the notes. Keep it short. Do not invent manual steps. When no source tells how the change was
   tested, omit the section and put a 🧪 line in the reply.
5. **Media** (optional): screenshots and videos.
   - Put a comparison (before and after, light and dark) in a table, with one column for each
     state.
   - Images: `<img src="<branch-slug>/after.png" alt="..." width="300">`. Videos:
     `![alt](<branch-slug>/demo.mp4)`.
   - Use a width of approximately 300 px for portrait screenshots and phone videos, also in tables.
   - The local relative paths are placeholders. They let a local Markdown preview show the media.
     Before it publishes, the wrapper uploads each file and replaces each path with the uploaded
     URL. If its platform needs a different syntax, the wrapper also changes the syntax.
   - When the diff changes reference images of screenshot tests, do not embed them. Write one line
     that tells the reviewer that the image diffs are in the changed files.
6. **Out of scope** (optional): only for clear cases: the next branches of a stack, or an
   important decision not to do something. Not for small decisions or for agent conversation
   context.
7. **Questions for reviewers** (optional): if the user asks for it or gives the questions, write
   this section.

### Review comments

- Each comment is an H2 with `` `path:line` ``, where the line is on the new side of the diff. The
  comment text follows.
- Use them for context that helps during the review: "start here", "moved code, no changes", "I
  chose X over Y because Z", "check this edge case", "this part is important".
- When the explanation stays true after merge, it belongs in a code comment. Add a review comment
  for it only to mark the code as important.
- Usually 0-3 comments. More only for large or high-impact changes, and that is rare.

## Reply

1. The path and the full content of the file.
2. One line for each item that applies, with its marker:
   - 🧹 Branch preparation and cleanup: the tracked branches and their bases, sync, restack, the
     squashed commits and the backup ref. Or "no git-spice, preparation skipped".
   - ✂️ Split suggestion: the commits contain parts that someone can review and merge separately,
     for example a refactor and a behavior change, or two independent features. Use this test, not
     the line count. A mechanical refactor of many files is not a reason to split. Suggest
     `git-spice branch split`.
   - 🚧 Draft suggestion: the description has high-impact changes, or the diff has high-risk code
     (concurrency, security, data migration).
   - 🧪 Manual check: a user-visible change, and no source tells how it was tested. Give the test
     steps, and the screenshots or video to capture during those steps.
   - 📸 Capture suggestion: a UI change with no media and no changed reference images of screenshot
     tests, and no 🧪 line already tells what to capture. Do not capture until the user asks.

When the user asks for changes, edit the same file.

## Watch

If a wrapper skill tells you to do this step after it publishes, do it. Else do not do it. You
get these from the wrapper:

- the watch command. It takes `--interval <seconds>` and `--mr <id>` once for each MR. It prints
  the events in the format below.
- the command that shows the logs of the failed jobs of a pipeline
- the command that retries a job

The text uses GitLab words: MR, pipeline, job. On GitHub, the same rules apply to PRs and checks.

The watch is a background Bash task. Each 120 seconds, it checks the MRs. If it finds events, it
stops. Then you handle the events, report, and start it again. Between events, the user can use
the session for other work.

### Rules

The user does these actions, never you:

- reply to a comment, resolve a thread, or react
- approve or merge
- mark an MR ready, or change its title, description, or labels

If these three conditions are true, the session is idle:

- the working tree is clean
- no rebase or merge is in progress
- you are not in the middle of a different task

If the session is not idle, do not do an auto-fix.

### Start

1. Run `git-spice log short --all=false --json --no-prompt`. For each branch object with `change`,
   take `change.id`. A branch with no `change` has no MR yet.
2. If there is no MR, tell it in one line and stop.
3. Run the watch command with `--interval 120` and one `--mr <change.id>` for each MR, as a
   background Bash task (`run_in_background: true`). If a watch task runs, do not start a new one.

If the user says "watch", start the watch. If the user says "stop watch", stop the task.

### Result

| Exit | Action                                                                                    |
| ---- | ----------------------------------------------------------------------------------------- |
| `0`  | Handle the events, report, and start again (see below).                                   |
| `1`  | Report the stderr text and send a notification. Do not start again.                       |
| `3`  | A new watch replaced this one. Do not start again. No notification.                       |
| `4`  | The deadline passed. Report it as below. Do not start again.                              |

On exit `4`, report that the watch stopped, list the open MRs, and tell the user to say "watch"
to start it again.

On exit `0`, the output has one JSON line for each event: `kind`, `iid`, `title`, `url`,
`actor`, `detail`, `branch`, and `path` and `line` for a comment on a diff line.

| `kind`                 | Action                                          | Report section       |
| ---------------------- | ----------------------------------------------- | -------------------- |
| `pipeline`, failed     | See "Pipeline failures"                         | Done or Needs you    |
| `conflict`             | See "Conflicts"                                 | Done or Needs you    |
| `merged`               | See "Merged MRs"                                | Info, Done/Needs you |
| `comment`              | See "Comments"                                  | Needs you            |
| `unaddressed`          | The thread waits for the user                   | Needs you            |
| all other kinds        | None                                            | Info                 |

A `comment` and an `unaddressed` line with the same `url` are one item.

After you handle the events, do "Start" again with the current list. A sync can delete a merged
branch, and the user can add a branch. If all MRs are merged or closed, do not start again. Tell
it in one line.

### Pipeline failures

Run the wrapper command for the logs of the failed jobs. Find the cause of each failed job.

- The cause is outside the branch: a runner or system failure, the network, a cache, or a service
  that is down. Retry the job with the wrapper command. A retry needs no idle session.
- The cause is a formatter or lint error, or an obvious compile error, in the code of the branch.
  If the session is idle, fix it:
  1. Switch to the branch of the MR. Remember the branch that was current.
  2. Make the fix.
  3. Run `~/.config/ai/bin/git-diff-context.sh --parent-only` and get `parent`.
  4. Run `~/.config/ai/bin/git-absorb-fixes.sh <parent> <file>...` with the changed files. If it
     reports a file under `needs-message`, the fix is not trivial. Undo it with
     `git restore --staged --worktree -- <file>...` and put the failure under Needs you.
  5. Run `~/.config/ai/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)"`.
  6. Run `git-spice upstack restack --no-prompt`.
  7. Run `git-spice stack submit --update-only --no-prompt`.
  8. Switch back to the branch that was current.

  If the session is not idle, put the failure under Needs you as "fix waits, session not idle",
  with the proposed fix. If the session is idle at the next report, or if the user asks, do the fix.
- All other causes: put the failure under Needs you, with the cause and a proposed fix. Do not
  change the code until the user asks.

### Conflicts

If the session is not idle, put the conflict under Needs you as "fix waits, session not idle".
Else run `git-spice repo sync --no-prompt` and `git-spice stack restack --no-prompt`.

- If the restack stops on a trivial conflict (imports, or adjacent lines that do not depend on
  each other), resolve it and continue the rebase.
- Else run `git rebase --abort` and put the conflict under Needs you, with the files.

When the restack succeeds, run `git-spice stack submit --update-only --no-prompt`.

### Merged MRs

If no open MR of the stack is above the merged MR, do nothing more. If the session is not idle,
put the restack under Needs you as "fix waits, session not idle". Else run
`git-spice repo sync --no-prompt`, `git-spice stack restack --no-prompt`, and
`git-spice stack submit --update-only --no-prompt`. On a restack conflict, do as in "Conflicts".

### Comments

Read the code at `path:line` and the thread. Then assess the comment:

- A suggestion: is it good? Why or why not?
- A reported bug: is it real?
- A question: propose an answer.

Put the assessment and a proposed fix or answer under Needs you. Do not change the code until the
user asks.

### Report

One block for each report. One group for each MR, in stack order from the bottom. Omit an empty
section.

```text
14:32 !123 Fix crash on rotation
https://gitlab.example.com/app/-/merge_requests/123

Needs you
1. @anna on NoteEditor.kt:42: "Why not rememberSaveable here?"
   Valid. rememberSaveable also keeps the text after process death.
   Proposed fix: replace the SavedStateHandle field (3 lines).

Done
- Pipeline 4567: ktlint failed in 2 files. Formatted, folded into abc1234, pushed.

Info
- @bob approved.
- @carol reacted :thumbsup: to your comment on NoteEditor.kt:42.
```

- Needs you shows all open items, also the items from earlier reports: the `unaddressed` threads
  of this result, the failures that wait for the user, and the fixes that wait. If the result
  shows that an item is addressed, the item leaves the list. Examples: the thread is not in
  `unaddressed`, or a new pipeline passed. Number the items. The user can then say "fix 1".
- Done and Info show only the events of this result.

### Notification

If `HERDR_ENV` is `1`, send one notification for each report. Replace each `'` in the text with a
space.

```sh
herdr notification show '<title>' --body '<body>' --sound <sound>
```

- Title: `!<iid>: <n> needs you`. If Needs you is empty, `!<iid>`. For more MRs: `<n> MRs`.
- Body: the most urgent item in one line, then the Done items. Example:
  `@anna asked on NoteEditor.kt:42. Pipeline fixed and pushed.`
- Sound: if there are new Needs you items, `request`. Else `none`.
