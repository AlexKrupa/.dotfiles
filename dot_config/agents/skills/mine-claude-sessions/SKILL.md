---
name: mine-claude-sessions
description: Use when the user asks to mine past Claude Code sessions of this repo for repeated corrections.
disable-model-invocation: true
argument-hint: "[session count or start date, e.g. \"last 20\"]"
---

# mine-claude-sessions

Finds corrections that the user gave the agent more than one time in past Claude Code sessions of
the current repo. It writes them to a findings file. Then it proposes repo instructions that stop
the repeats, and it writes only the instructions that the user approves.

The findings file does not depend on one agent tool. A later run, the user, or another tool can read
it.

## Limits

- Write only to `~/.ai/<repo>/mined/` and to the target file of an approved finding.
- Do not edit global files: `~/.config/agents/*`, `~/.claude/CLAUDE.md`, global rules, global
  skills. When a finding applies to all repos, tell the user and let them edit the global file
  manually.
- Do not write `.claude/rules/`. It works only in Claude Code.
- Outside a git repo, stop.

## 1. Extract the candidates

Turn the user's request into options for the helper script:

| Request                            | Options                 |
| ---------------------------------- | ----------------------- |
| nothing                            | `--limit 50`            |
| "last 20 sessions"                 | `--limit 20`            |
| "since 2 weeks", "since October 1" | `--since <YYYY-MM-DD>`  |
| "again", "all", "re-mine"          | `--all` (ignores state) |

```bash
bash "${CLAUDE_SKILL_DIR}/sessions.sh" extract --exclude "${CLAUDE_SESSION_ID}" <options>
```

The script finds the sessions of all worktrees of the repo, in `~/.claude/projects/` and in
`~/.claude-sandbox/config/projects/`. It skips sessions that an earlier run read, unless they have
new lines. It prints the path of the candidates file and the counts. If the count of new sessions
is 0, tell the user and stop.

Each line in the candidates file is one JSON object:

- `kind: "message"`: a short user message. Most of them are tasks, not corrections.
- `kind: "interrupt"`: the user stopped the agent. `before` is the agent action that they stopped.
- `kind: "rejected"`: the user rejected a tool call. `before` is the tool call. If the user gave a
  reason, `text` is the reason.

Read the whole file. If the file is large, read it in parts.

## 2. Find and group the corrections

A correction is an event where the user tells the agent that its action or plan was wrong. It can
also tell the agent how to do the work next time. Examples: "no, use X", "do not do Y", "I said Z", "stop", an interrupt, a
rejected tool call. To understand an interrupt or a rejection, read the next user message of the
same session. It often gives the reason.

Ignore:

- tasks, answers to questions of the agent, and approvals
- corrections of a fact about the current task only ("the file is in `src/`, not `lib/`"), because
  they do not apply again
- headless sessions with scripted prompts, for example "Run exactly this with Bash"

If corrections ask for the same behavior, put them in one group. The words can be different. A finding
needs 2 or more corrections in 2 or more sessions. Put the single corrections in "Seen once".

Read the "Seen once" sections and the decisions in the earlier findings files in
`~/.ai/<repo>/mined/`. A correction that matches an earlier "Seen once" entry is a repeat. If an earlier
file marks a finding as skipped, do not propose it again. If the user corrected it again, mention
it.

For each finding, search `CLAUDE.md`, `CLAUDE.local.md`, and `AGENTS.md` files in the repo for a
rule that already covers it. If a rule exists, the agent ignored it. Then propose a more specific
rule in the place of the existing rule, not a second rule.

## 3. Write the findings file

Path: `~/.ai/<repo>/mined/YYYY-MM-DD-sessions.md`, from the "mined dir" line of the script. If the
file exists, add `-2`, `-3`, and so on.

Use this format. Write in ASD-STE100 Simplified Technical English. Quote the user exactly.

```markdown
# Mined corrections: Claude Code sessions, 2026-10-16

Sessions: 50 read, 12 not read. Period: 2026-09-01 - 2026-10-15.

## 1. Run Gradle in quiet mode

- Count: 3 in 2 sessions (`28b36710`, `652399a9`)
- Status: new
- Target: `CLAUDE.local.md`
- Decision: pending
- Evidence:
  - "use -q, the output is too long" (after: `Bash: ./gradlew build`)
  - Rejected `Bash: ./gradlew test`: "quiet mode"
- Proposed rule: Run Gradle commands with `-q`. Remove `-q` only to debug a failure.

## Seen once

- "do not open the browser" (`a2788774`, after: `Bash: open index.html`)
```

Status is `new` or `rule exists, the agent ignored it (<file>:<line>)`. If no finding has 2 or more
corrections, write only the header and "Seen once".

After the file is saved, save the state:

```bash
bash "${CLAUDE_SKILL_DIR}/sessions.sh" save-state
```

## 4. Propose the targets and get approval

Default target: `CLAUDE.local.md` in the root of the current worktree. Other targets:

- If all evidence is about one subdir: `<subdir>/CLAUDE.local.md`.
- If the status is "rule exists": the existing rule.
- If the finding applies to all repos: the global instructions. Do not write them. Give the user
  the rule text.

Show the findings in the chat as a numbered list: title, count, proposed rule, target. Ask the user
to answer for each number: yes, edit with new text, or no. Ask in the reply, not with a question
tool.

Before you write, run `git ls-files --error-unmatch <target>`. If git tracks the target, tell the
user that the rule becomes visible to the team, and ask again. If the current worktree is a linked
worktree, tell the user that an untracked `CLAUDE.local.md` exists only in this worktree.

Write the approved rules. Keep the style of the target file. Then set `Decision` in the findings
file to `approved`, `edited`, or `skipped`. Tell the user the path of the findings file and the
files that you changed.
