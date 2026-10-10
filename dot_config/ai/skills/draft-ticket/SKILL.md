---
name: draft-ticket
description:
  Writes one ticket draft (task, bug, or spike) as a Markdown file under ~/.ai/<repo>/tickets/,
  for any issue tracker. Run only when the user calls /draft-ticket or when the instructions of
  another skill tell you to run draft-ticket. Do not run it for other requests about tickets,
  issues, or bug reports.
argument-hint: "<what the ticket is about>"
---

# draft-ticket

Writes one ticket draft as a Markdown file. The file is input for a later step: a person or another
skill copies it, translates it, or publishes it to an issue tracker. This skill does not know the
tracker and does not publish. After the publish, the caller can give the real ticket id. Then this
skill puts the real id in place of the placeholder id (see "Real ticket id").

## Output rules

- Write in English, in ASD-STE100 Simplified Technical English, also when the prompt or the sources
  use a different language. STE text translates well.
- The ticket describes work that is not done yet. The reader is the person who will do the work.
  When the source is finished work (a branch, a plan, a conversation after the implementation),
  describe the problem and the required result. Do not describe the code that exists. Do not say
  that something is done, added, or implemented.
- Do not mention the sources: no "as discussed", "from the brainstorm", "on this branch", and no
  links to local files.
- Keep the ticket high level. Do not write names of classes, functions, files, or libraries, or the
  code structure. Write a selected approach only when it changes the result: behavior, UX, API
  contract, data format, or scope.
- When the user asks for implementation details, put them only in "Implementation notes".
- Write only what the sources and the user state. Do not add requirements, edge cases, checks,
  questions, numbers, or impact of your own. A short source gives a short ticket.
- Write each fact one time, in one section.
- When an optional section has no content, do not write it. No "None" or "N/A".
- Make the ticket easy to scan: short paragraphs of 1-3 sentences, and lists for items.
- Write each paragraph and each list item on one line, with no hard line breaks. Issue trackers
  show a line break in a paragraph as a new line.

## Ticket format

Frontmatter with only `type` (`task`, `bug`, or `spike`), then the H1 title, then the `##` sections
of the type, in the order below.

```markdown
---
type: task
---

# Add CSV export of all notes

## Context
```

Title:

- Task: imperative, for example "Add CSV export of all notes".
- Bug: the symptom, for example "App closes when the user rotates the note editor".
- Spike: a question or a topic, for example "Compare options for note sync between devices".
- No type prefix. Approximately 80 characters or less.

Sections that more than one type uses:

- **Out of scope** - work that this ticket does not include, also alternatives that were rejected,
  with the reason when the sources give one.
- **Open questions** - points that the user or the sources leave open.
- **References** - links to issues, documents, designs, and web pages.

### Task

1. Context - why the change is necessary: the problem, the cause of the ticket, and the expected
   improvement.
2. Requirements - a list of the required results. Each item is a pass/fail check that the user or a
   tester can observe, for example "Settings > Data has an option that starts the export". The
   list is also the acceptance criteria, so do not write a separate section for them.
3. Out of scope (optional)
4. Implementation notes (only when the user asks)
5. Open questions (optional)
6. References (optional)

### Bug

1. Environment - the values that apply, for example device, OS version, app version, frequency
   (always, sometimes, once), and last working version. Write "Unknown" for an unknown value.
2. Steps to reproduce - a numbered list.
3. Actual behavior
4. Expected behavior
5. Impact (optional) - only from data or from a statement of the user. Do not estimate it.
6. Logs and screenshots (optional)
7. Workaround (optional)
8. Open questions (optional)
9. References (optional)

### Spike

1. Context
2. Questions to answer
3. Expected output - the deliverable (for example a document, a decision, or a prototype) and what
   it must contain.
4. Acceptance criteria - pass/fail checks of the deliverable, for example "Compares all 3 options".
   Each check tests a question or a fact from the sources.
5. Out of scope (optional)
6. Open questions (optional)
7. References (optional)

## Workflow

1. Find the type from the prompt and the conversation. State it in one line, for example
   "Type: bug". Ask only when the type is not clear.
2. Collect the context. Do the research yourself, with no subagents. Keep it short, a few reads,
   unless the user asks for deep research.
   - Always: the prompt and the current conversation.
   - Plans, specs, the branch diff, or commits: only when the user points to them, for example
     "this branch" or a file path.
   - The codebase and linked URLs or issues: when they help to describe the problem or the current
     behavior.
3. If the scope contains results that someone can deliver separately, tell the user and propose a
   split. Then write one ticket for the part that the user selects.
4. If a required section has no content from the sources, ask the user. Ask in the reply text.
   - Put independent questions in one numbered list. Give a recommended answer when you have one.
   - Ask a question that depends on a different answer only after you get that answer.
   - When the user does not know an answer, put the point in "Open questions". For a bug
     environment value, write "Unknown".
   - When all required sections have content, do not ask. Write the file.
5. Get the path and write the file there:

   ```sh
   path="$(~/.config/ai/bin/ticket-path.sh "<title>")"
   ```

6. Show the path and the full content of the file. When the user asks for changes, edit the same
   file.

## Real ticket id

Conditions for these steps:

- The caller gives the real id of the ticket that you wrote.
- The name of the current branch starts with the placeholder ticket id and `/`, for example
  `ABC-0/`. The project instructions give the placeholder id.

If the two conditions are true, do these steps. Do not ask before you start.

1. Select the branches. The current branch is always one of them. You can add a branch below it
   in the git-spice stack (`git-spice log short --json`). If its name also starts with the
   placeholder id and its commits were a source of the ticket, add it.
2. Run the script. It renames the branches, puts the id in the commit messages and in the lines
   that the branches added, and renames the herdr workspace and the Claude session. Put the
   ticket title in single quotes, with each `'` replaced by a space.

   ```sh
   ~/.config/ai/bin/ticket-id-rename.sh <placeholder> <ticket-id> <branch>... --title '<title>'
   ```

3. Exit `2`: the branches are pushed. Each `pushed:` line gives a branch and its upstream. If
   git-spice knows the MR of the branch, the line also gives the MR URL. Look for an open MR in
   the line, or with the code host tool from the project instructions.
   - If a branch has an open MR, stop and ask the user. After a rename, the MR stays on the old
     remote branch.
   - If no branch has an open MR, run the same command again with `--push`.
   - If you cannot find out, ask the user.
4. Exit `1` or `3`: show the stderr text to the user, word for word, and stop.
5. Rename each file in `~/.ai/<repo>/{specs,plans,reviews}` that this session read or wrote and
   that has the placeholder id in its name. Put the real id in place of the placeholder id.
6. Show the output lines of the script and the renamed files. If a line starts with
   `session: manual`, tell the user to type the command in that line.
