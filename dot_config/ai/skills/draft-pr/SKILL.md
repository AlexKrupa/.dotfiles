---
name: draft-pr
description:
  Writes one pull request or merge request draft (title, description, metadata, review comments)
  as a Markdown file under ~/.ai/<repo>/prs/, for any code host. Run only when the user calls
  /draft-pr or when the instructions of another skill tell you to run draft-pr. Do not run it for
  other requests about pull requests or merge requests.
argument-hint: "[draft] [notes]"
---

# draft-pr

Writes one PR draft as a Markdown file: metadata, title, description, and review comments. A person
or a wrapper skill (for example a GitLab `/mr` skill) reads the file and publishes it. This skill
does not know the code host. It does not push and does not publish.

Before it writes, it prepares the branch: it syncs and restacks with git-spice, and it squashes
repair commits. The reviewer gets a clean branch and a description that agrees with it.

The goal is a PR that reviewers want to review. Give them all relevant facts and no wall of text.

## Arguments

- `draft` - write `draft: true` in the metadata. Without it, write `draft: false`.
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

The git-spice trunk is the `trunk` field of `git show refs/spice/data:repo`. Read it only when
`git rev-parse --verify -q refs/spice/data` succeeds. Do not run a `git-spice` command for it.

### 2. Branch preparation

Give each `git-spice` command `--no-prompt`, after the subcommand. A prompt stops a session that
has no terminal. The flag after the subcommand keeps the command in the form of the permission
rules, for example `git-spice log:*`.

```sh
git rev-parse --verify -q refs/spice/data && git-spice log short --json --no-prompt
```

Check `refs/spice/data` first. In a repo with no git-spice data, `git-spice log short` initializes
git-spice, and that changes a repo that does not use it.

If the command fails, or no output object has `"name"` equal to the current branch, git-spice
does not track the branch. Skip the git-spice commands in this step and in step 3, and tell it in
the 🧹 line of the reply.

Else run:

```sh
git-spice repo sync --no-prompt
git-spice stack restack --no-prompt
```

`repo sync` pulls mainline and deletes the local branches whose PRs are merged. If it fails, for
example with no network, continue, and tell it in the 🧹 line. `stack restack` rebases each branch
of the stack on its base. For a branch with no stack, it rebases only that branch. If it fails, for
example on a conflict, stop. Show its output. Do not resolve the conflict.

Then run `git-spice --no-prompt log short --json` again. `repo sync` can delete the lower branch
and move the current branch onto mainline. Then the first output is out of date.

### 3. Commit cleanup

A PR branch is always clean. Do this step with no confirmation.

1. Run `~/.config/ai/bin/git-diff-context.sh` and get `parent` from its output.
2. Read `~/.config/ai/references/commit-history.md` and apply its rules to `<parent>..HEAD`.
3. If the rules flag commits, or a subject in the range starts with `fixup!` or `amend!`, run the
   script with the merge base, not with `parent`. When step 2 did not run, `parent` can be a newer
   `origin/main`, and the script then rebases the branch onto it:

   ```sh
   ~/.config/ai/bin/git-squash-fixups.sh "$(git merge-base <parent> HEAD)" [<repair>:<target>...]
   ```

   Give one `<repair>:<target>` for each flagged commit. The script also squashes all `fixup!` and
   `amend!` commits. If it exits non-zero, stop. Show its output and the backup ref.
4. If the script changed commits, and the object of the current branch in the second
   `log short --json` output has `ups`, run `git-spice --no-prompt upstack restack`. Else the
   branches above stay on the old commits.

### 4. Analysis

If step 3 changed commits, run `git-diff-context.sh` again. Then read:

- the commit log and the output of the emitted `diff-command`
- the conversation and the notes from the arguments
- the sources that the user points to: a ticket, a plan, a spec, a URL
- the code around the diff, only when the diff alone does not explain a change

Read enough to find the changes, the high-impact changes, the focus files, and the code for review
comments. Do not look for defects. That is the job of `review-diff`.

### 5. Local conventions

Skip this step when a calling skill tells you to ignore the local conventions.

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
Put media files in `media`. Create that directory only when there are media files.

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

Start here - this is the core change.
```

- The first H1 is the title. The description is all text between the title and
  `# Review comments`. A wrapper splits the file on the `# Review comments` heading.
- The `---` line before `# Review comments` is only a visual marker. Put an empty line above it.
  Without the empty line, Markdown makes the previous paragraph a heading.
- When there are no review comments, omit the `---` line and the `# Review comments` part.

Metadata fields. The wrapper uses them to select the labels of its platform.

- `type` - one of `feature`, `fix`, `refactor`, `chore`, `docs`, `test`, `build`, `perf`.
- `draft` - from the arguments.
- `base` - the `parent` of the last `git-diff-context.sh` run, with no remote prefix (`origin/main`
  is `main`). The script reads the stack parent from git-spice after the sync.
- `ticket` - the ticket id. Omit the field when there is no ticket.
- `breaking` - `true` only for a contract break or a one-way door from "High-impact changes".

## Content rules

### General

- Write in English, in ASD-STE100 Simplified Technical English.
- Use short paragraphs. Write each paragraph or list item on one line, with no hard line breaks.
  Code hosts show a line break in a paragraph as a new line.
- Use a list for separate, parallel items: links, files, test steps, independent changes. Use a
  paragraph when the sentences explain one idea, for example a cause and its result, or steps of
  one flow.
- A section with only one item has no list. Write `On an emulator, a search for "milk" finds the
  note.`, not `- On an emulator, a search for "milk" finds the note.` This applies to each section,
  also Testing and Out of scope.
- Write only what the sources state. A small change gives a short description.
- When an optional section has no content, do not write it. No "None" or "N/A".
- Each link has text, for example `[ABC-123: Ticket title](url)`. Never a bare URL.

### Title

- Tell what changes, not how: "Change foo to get bar", "Fix situations when foo does bar".
- Use implementation words only when the change is an implementation detail, for example build or
  infrastructure work.
- Approximately 72 characters or less. No prefix, unless the local convention has one.

### Description

Sections, in this order:

1. **Context** (required) - why the change is necessary, in 1-3 sentences. Links to what caused
   the change: the ticket, an issue, a design (for example Figma). Put one link above the text. Put
   two or more links in a list above the text.
2. **Changes** (required) - what changes in behavior, UX, API, and data, at a high level. Add only
   the implementation details that have high impact. Put links that helped to make the change
   (external docs, internal docs, API reference) inline, next to the change that they explain.
   - `### High-impact changes` (optional) at the end of Changes. Use the criteria in
     `~/.config/ai/references/review-guide.md`, section "High-impact changes". Most PRs have none.
3. **How to review** (optional) - only when the diff is not a simple change. Use the focus files
   and their order from `~/.config/ai/references/review-guide.md`, section "Focus files". Recommend
   a review commit by commit only when there are 2 or more commits and each commit has value by
   itself.
4. **Testing** - the automated tests from the diff, and the manual testing from the conversation
   or the notes. Keep it short. Do not invent manual steps. When no source tells how the change was
   tested, omit the section and put a 🧪 line in the reply.
5. **Media** (optional) - screenshots and videos.
   - Put a comparison (before and after, light and dark) in a table, with one column for each
     state.
   - Images: `<img src="<branch-slug>/after.png" alt="..." width="300">`. Videos:
     `![alt](<branch-slug>/demo.mp4)`.
   - Use a width of approximately 300 px for portrait screenshots and phone videos, also in tables.
   - The local relative paths are placeholders. They let a local Markdown preview show the media.
     Before it publishes, the wrapper uploads each file, replaces each path with the uploaded URL,
     and changes the syntax when its platform needs it.
   - When the diff changes reference images of screenshot tests, do not embed them. Write one line
     that tells the reviewer that the image diffs are in the changed files.
6. **Out of scope** (optional) - only for clear cases: the next branches of a stack, or an
   important decision not to do something. Not for small decisions or for agent conversation
   context.
7. **Questions for reviewers** (optional) - only when the user asks for it or gives the questions.

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
   - 🧹 Branch preparation and cleanup: sync, restack, the squashed commits and the backup ref. Or
     "git-spice does not track this branch - preparation skipped".
   - ✂️ Split suggestion: the commits contain parts that someone can review and merge separately,
     for example a refactor and a behavior change, or two independent features. Use this test, not
     the line count. A mechanical refactor of many files is not a reason to split. Suggest
     `git-spice branch split`.
   - 🚧 Draft suggestion: the description has high-impact changes, or the diff has high-risk code
     (concurrency, security, data migration).
   - 🧪 Manual check: a user-visible change, and no source tells how it was tested. Give the test
     steps, and the screenshots or video to capture during those steps.
   - 📸 Capture suggestion: a UI change with no media and no changed reference images of screenshot
     tests, when no 🧪 line already tells what to capture. Do not capture until the user asks.

When the user asks for changes, edit the same file.
