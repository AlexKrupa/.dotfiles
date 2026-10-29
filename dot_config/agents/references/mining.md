# Mining: shared rules

Rules for the `mine-*` skills. A mine skill reads one source (sessions, PR comments), finds the
topics that repeat, writes a findings file, and proposes repo instructions. The source skill
tells you how to extract and what counts as a signal. This file tells you the rest.

## Limits

- Write only to `~/.ai/<repo>/mined/` and to the target file of an approved finding.
- Do not edit global files: `~/.config/agents/*`, the global agent instruction file, global
  rules, global skills. When a finding applies to all repos, tell the user and let them edit the
  global file manually.
- Do not write the rule folders of one agent, for example `.claude/rules/`. Other agents do not
  read them.
- Outside a git repo, stop.

## Repeats

A finding needs 2 or more signals from 2 or more sources (sessions, PRs). Put the single signals
in "Seen once".

Read the "Seen once" sections and the decisions in the earlier findings files of the same source
in `~/.ai/<repo>/mined/`. A signal that matches an earlier "Seen once" entry is a repeat. If an
earlier file marks a finding as skipped, do not propose it again. If the signal came again,
mention it.

For each finding, search the `CLAUDE.md`, `CLAUDE.local.md`, and `AGENTS.md` files in the repo
for a rule that already covers it. If a rule exists, people or agents ignored it. Then propose a
more specific rule in the place of the existing rule, not a second rule. If only a project doc
(for example `docs/`, `CONTRIBUTING.md`) has the rule, the proposed rule points to that doc.

## Findings file

Path: `~/.ai/<repo>/mined/YYYY-MM-DD-<source>.md`. If the file exists, add `-2`, `-3`, and so on.

Use this format. Write in ASD-STE100 Simplified Technical English. Quote people exactly. The
source skill defines the IDs and the evidence lines.

```markdown
# Mined <signals>: <source>, 2026-10-16

<Source counts>. Period: 2026-09-01 - 2026-10-15.

## 1. Run Gradle in quiet mode

- Count: 3 in 2 <sources> (`<id>`, `<id>`)
- Status: new
- Target: `<the local agent instruction file of the repo>`
- Decision: pending
- Evidence:
  - <evidence line>
  - <evidence line>
- Proposed rule: Run Gradle commands with `-q`. Remove `-q` only to debug a failure.

## Seen once

- <evidence line>
```

Status is `new` or `rule exists (<file>:<line>)`. If no finding has 2 or more signals, write only
the header and "Seen once".

## Targets and approval

Default target: the local agent instruction file of the repo, in the root of the current worktree.
Other targets:

- If all evidence is about one subdir: the local agent instruction file of the repo in that subdir.
- If the status is "rule exists": the existing rule.
- If the finding applies to all repos: the global instructions. Do not write them. Give the user
  the rule text.

Show the findings in the chat as a numbered list: title, count, proposed rule, target. Ask the user
to answer for each number: yes, edit with new text, or no. Ask in the reply, not with a question
tool. The last line of the reply is `` 📄 Findings: `<path>` ``.

Before you write, run `git ls-files --error-unmatch <target>`. If git tracks the target, tell the
user that the rule becomes visible to the team, and ask again. If the current worktree is a linked
worktree, tell the user that an untracked local agent instruction file of the repo exists only in
this worktree.

Write the approved rules. Keep the style of the target file. Then set `Decision` in the findings
file to `approved`, `edited`, or `skipped`. Tell the user the path of the findings file and the
files that you changed. The last lines of the reply are `` 📄 Findings: `<path>` ``, then the
changed files in the format of the output style.
