---
name: mine-prs
description: Use when the user asks to mine reviewer comments on merged PRs or MRs of this repo for repeated topics.
disable-model-invocation: true
argument-hint: "[MR count or start date, for example \"last 20\"]"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/prs.sh *)
---

# mine-prs

Finds the topics that reviewers write about more than one time in the merged PRs of the current
repo. It writes them to a findings file. Then it proposes repo instructions so that the agent
gets the topic right before review, and it writes only the instructions that the user approves.
"PR" means a pull request or a merge request.

Read `~/.config/agents/references/mining.md` first. It has the limits, the repeat rules, the
findings format, and the approval steps. This file adds what is special to PRs.

## 1. Extract the remarks

Turn the user's request into options for the helper script:

| Request                            | Options                 |
| ---------------------------------- | ----------------------- |
| nothing                            | `--limit 50`            |
| "last 20 MRs"                      | `--limit 20`            |
| "since 2 months", "since October 1" | `--since <YYYY-MM-DD>` |
| "again", "all", "re-mine"          | `--all` (ignores state) |

```bash
bash "${CLAUDE_SKILL_DIR}/prs.sh" extract <options>
```

The script uses `glab` (GitLab). It reads the merged MRs of the current repo, newest first, and
skips the MRs that an earlier run read. It removes system notes, bots, and threads that the MR
author started. It prints the path of the candidates file and the counts. If it read 0 MRs, tell
the user and stop. If the exit code is 4, give the user the error message and stop.

Each line in the candidates file is one thread:

- `body`: the first comment of the reviewer. `author` is the reviewer.
- `replies`: the replies in the thread, also from the MR author.
- `path`, `line`: the commented code. Both are `null` for a comment that is not on a line.
- `changed`: `yes`, `no`, or `unknown`. When a later push changed the commented lines or the
  author applied a suggestion, the value is `yes`. When the script cannot tell, it is `unknown`.
- `mine`: when the current user wrote the MR, the value is `true`.

Read the whole file. If the file is large, read it in parts.

## 2. Find and group the topics

A remark is a comment that asks for, proposes, or questions a choice in the code or in the work.
People write remarks in many forms:

- request: "please rename this", "this must be private"
- nit: "nit: trailing comma"
- suggestion: a `suggestion` block, "maybe extract this?"
- question: "why not `when` here?"
- thought: "at some point we can ..."
- reminder: the remark points to a convention, a doc, or a habit of the team. Examples: "per
  `docs/architecture.md`", "see CONTRIBUTING", "we always ...", "reminder: ...". A reminder shows
  a rule that people know but that is not where the author looks.

Ignore:

- praise, "LGTM", and replies that only say thanks or "done"
- remarks about the logic of one MR only ("off by one here"), because they do not apply again
- questions that only ask for information about the MR

If remarks ask for the same convention, put them in one group. The words, the form, and the
reviewer can be different. Then apply "Repeats" from the reference. A remark is one signal, and
an MR is one source.

Rate each remark. A remark with `changed: yes`, or with a reply where the author agrees, is a
strong signal. A remark that nobody answered is a weak signal. If the author disagreed and did
not change the code, keep the remark and mark the finding as disputed. Sort the findings by
count, then by the number of strong signals.

## 3. Write the findings file

Write `~/.ai/<repo>/mined/YYYY-MM-DD-prs.md` in the format of the reference. Get the dir from the
"mined dir" line of the script. Use these values:

- Title: `# Mined review remarks: merged PRs, <date>`
- Counts line: `MRs: 50 read, more over the limit: no. Remarks: 120.`
- IDs: the MR reference, for example `!101`.
- Status: if an author disagreed, add `, disputed (!105)`.
- Evidence lines: the MR, the reviewer, the kind, the change signal, and a short exact quote.
  Add `(mine)` for the MRs of the current user. For example:

  ```markdown
  - !101 kim, nit, changed: "please use our `AppLogger` instead of `Log.d`" (mine)
  - !105 kim, question, not changed, author disagreed: "I would prefer a `when` here"
  ```

For a reminder group, the proposed rule gives the convention itself. If a doc has the
convention, the rule points to the doc. If no doc of the repo has it, tell the user that the team
docs can be a better place later. The target stays as the reference says.

After the file is saved, save the state:

```bash
bash "${CLAUDE_SKILL_DIR}/prs.sh" save-state
```

## 4. Propose the targets and get approval

Follow "Targets and approval" in the reference.
