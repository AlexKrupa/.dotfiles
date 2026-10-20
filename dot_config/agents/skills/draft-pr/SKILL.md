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
of the stack on its base. For a branch with no stack, it rebases only that branch. If it stops on
a conflict, do "Restack conflicts". If it fails for a different cause, stop and show its output.

#### Restack conflicts

- If the conflict is trivial (imports, or adjacent lines that do not depend on each other),
  resolve it, stage the files, and run `git-spice rebase continue --no-edit --no-prompt`. It
  continues the restack of the full stack. Do not use `git rebase --continue`: it continues only
  the current rebase, and it can open an editor. If the restack stops again, do this rule again.
  Then run the validation of the repo: tests, type check, lint. Look in the `package.json`
  scripts, `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, and similar files. If the
  validation fails, stop and show the command and the error. Name the resolved files in the 🧹
  line.
- Else run `git-spice rebase abort --no-prompt` and stop. Name the files of the conflict. The user
  decides how to resolve it.

Then run `git-spice log short --json --no-prompt` again. `repo sync` can delete the lower branch
and move the current branch onto mainline. Then the first output is out of date.

### 3. Commit cleanup

A PR branch is always clean. Do this step and do not ask the user first.

1. Run `~/.config/agents/bin/git-diff-context.sh` and get `parent` from its output.
2. Read `~/.config/agents/references/commit-history.md` and apply its rules to `<parent>..HEAD`.
3. If the rules flag commits, or a subject in the range starts with `fixup!` or `amend!`, run the
   script with the merge base, not with `parent`. When step 2 did not run, `parent` can be a newer
   `origin/main`, and the script then rebases the branch onto it:

   ```sh
   ~/.config/agents/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)" [<repair>:<target>...]
   ```

   Give one `<repair>:<target>` for each flagged commit. The script also squashes all `fixup!` and
   `amend!` commits. If it exits non-zero, stop. Show its output and the backup ref. A `fixup!`
   commit whose target is below `parent` stays. Name it in the 🧹 line. The script also restacks
   the git-spice branches above the current branch.

### 4. Reuse check

```sh
~/.config/agents/bin/pr-path.sh
~/.config/agents/bin/pr-draft-reuse.sh <file> <parent>
```

`<file>` is the `file` value of `pr-path.sh`. `<parent>` is the `parent` value of step 3. The
script prints `reuse`, `reason`, `diff-base`, and `diff-head`. If the branch's own diff did not
change since the last full write of the draft, the script prints `reuse=yes`. A rebase onto a new
base is not a change.

- `reuse=yes`: skip steps 5 to 7. In the file, set `base` (see "File format"), `draft` from the
  arguments, `diff-base`, and `diff-head`. If the arguments have notes, add them to the sections
  that they are about, for example Testing. Do not write the other sections again. The user's
  edits in the file stay. Tell "draft reused, no content change" in the 🧹 line. Go to step 8.
- `reuse=no`, or the user asks for a new draft: continue with step 5.
- If the script exits `1`, stop and show its error.

### 5. Analysis

If step 3 changed commits, run `git-diff-context.sh` again. Then read:

- the commit log and the output of the emitted `diff-command`
- the conversation and the notes from the arguments
- the sources that the user points to: a ticket, a plan, a spec, a URL
- if the diff alone does not explain a change, the code around the diff

Read enough to find the changes, the high-impact changes, the focus files, and the code for review
comments. Do not look for defects. That is the job of `review-diff`.

### 6. Local conventions

If a calling skill tells you to ignore the local conventions, skip this step.

- PR template: `.github/pull_request_template.md`, `.github/PULL_REQUEST_TEMPLATE/`, or
  `.gitlab/merge_request_templates/`. If one exists, use its sections in place of the sections in
  "Description", and fill them with the content rules of this skill.
- Title convention: `CONTRIBUTING.md`, and the last 20 subjects on mainline
  (`git log --first-parent --format=%s -20 <mainline>`). If they show a pattern, for example a
  ticket prefix or a type prefix, use it.

### 7. Write the file

Write the draft to the `file` path of step 4. If the file exists, edit it. Keep the user's text
where it still agrees with the diff. Name the sections that you replaced in the 🧹 line. Set
`diff-base` and `diff-head` from the output of step 4. Put media files in the `media` path of
`pr-path.sh`. If there are media files, create that directory.

### 8. Reply

See "Reply".

## File format

```markdown
---
type: fix
draft: false
base: main
ticket: ABC-123
breaking: false
diff-base: 3f9c2a1d8e7b6a5f4c3d2e1f0a9b8c7d6e5f4a3b
diff-head: 8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b
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
- `diff-base`, `diff-head`: the merge base and the head of the branch at the last full write. Step
  4 uses them. A wrapper skill does not use them.

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
     `~/.config/agents/references/review-guide.md`, section "High-impact changes". Most PRs have none.
3. **How to review** (optional): if the diff is not a simple change, write this section. Use the
   focus files and their order from `~/.config/agents/references/review-guide.md`, section "Focus
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

- Each comment is an H2 with `` `path:line` `` or `` `path:start-end` ``. The lines are on the new
  side of the diff. The comment text follows.
- If the comment is about a block, for example a function, use a range that covers the block. Do
  not use only its first line, its doc comment, or its signature. If the block is long, use the
  range of the part that the comment is about.
- Use them for context that helps during the review: "start here", "moved code, no changes", "I
  chose X over Y because Z", "check this edge case", "this part is important".
- When the explanation stays true after merge, it belongs in a code comment. Add a review comment
  for it only to mark the code as important.
- Usually 0-3 comments. More only for large or high-impact changes, and that is rare.

## Reply

1. The full content of the file.
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

3. The last line: `` 📄 PR draft: `<path>` ``.

When the user asks for changes, edit the same file. Each reply that changes the file ends with the
`📄 PR draft:` line.

## Watch

If a wrapper skill tells you to do this step after it publishes, do it. Else do not do it. You
get these from the wrapper:

- the watch command. It takes `--interval <seconds>` and `--mr <id>` once for each MR. It prints
  the events in the stack mode format of `watch-gitlab.sh`.
- the command that shows the logs of the failed jobs of a pipeline
- the command that retries a job

Read `~/.config/agents/references/watch-gitlab-mr.md` first. It tells how to run the watch task,
handle its exit codes, report, and send notifications. This section tells only the author
actions.

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
3. Run the watch command with one `--mr <change.id>` for each MR, as the reference tells.

### Events

| `kind`                 | Action                                          | Report section       |
| ---------------------- | ----------------------------------------------- | -------------------- |
| `pipeline`, failed     | See "Pipeline failures"                         | Done or Needs you    |
| `conflict`             | See "Conflicts"                                 | Done or Needs you    |
| `merged`               | See "Merged MRs"                                | Info, Done/Needs you |
| `comment`              | See "Comments"                                  | Needs you            |
| `own-comment`          | See "Own comments" in the reference             | Info or Needs you    |
| `unaddressed`          | The thread waits for the user                   | Needs you            |
| all other kinds        | None                                            | Info                 |

After you handle the events, do "Start" again with the current list. A sync can delete a merged
branch, and the user can add a branch. If all MRs are merged or closed, do not start again. Tell
it in one line.

Needs you also shows the failures that wait for the user, and the fixes that wait.

### Pipeline failures

Run the wrapper command for the logs of the failed jobs. Find the cause of each failed job.

- The cause is outside the branch: a runner or system failure, the network, a cache, or a service
  that is down. Retry the job with the wrapper command. A retry needs no idle session.
- The cause is a formatter or lint error, or an obvious compile error, in the code of the branch.
  If the session is idle, fix it:
  1. Switch to the branch of the MR. Remember the branch that was current.
  2. Make the fix.
  3. Run `~/.config/agents/bin/git-diff-context.sh --parent-only` and get `parent`.
  4. Run `~/.config/agents/bin/git-absorb-fixes.sh <parent> <file>...` with the changed files. If it
     reports a file under `needs-message`, the fix is not trivial. Undo it with
     `git restore --staged --worktree -- <file>...` and put the failure under Needs you.
  5. Run `~/.config/agents/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)"`.
  6. Run `git-spice stack submit --update-only --no-prompt`.
  7. Switch back to the branch that was current.

  If the session is not idle, put the failure under Needs you as "fix waits, session not idle",
  with the proposed fix. If the session is idle at the next report, or if the user asks, do the fix.
- All other causes: put the failure under Needs you, with the cause and a proposed fix. Do not
  change the code until the user asks.

### Conflicts

If the session is not idle, put the conflict under Needs you as "fix waits, session not idle".
Else run `git-spice repo sync --no-prompt` and `git-spice stack restack --no-prompt`. On a
conflict, do "Restack conflicts" of step 2. If it stops, put the conflict or the failed validation
under Needs you, with the files.

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

If an `own-comment` is a review comment of the PR draft file, do not check it. You wrote it.
