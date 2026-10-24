---
name: mine-claude-sessions
description: Use when the user asks to mine past Claude Code sessions of this repo for repeated corrections.
disable-model-invocation: true
argument-hint: "[session count or start date, for example \"last 20\"]"
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/sessions.sh *)
---

# mine-claude-sessions

Finds corrections that the user gave the agent more than one time in past Claude Code sessions of
the current repo. It writes them to a findings file. Then it proposes repo instructions that stop
the repeats, and it writes only the instructions that the user approves.

The findings file does not depend on one agent tool. A later run, the user, or another tool can read
it.

Read `~/.config/agents/references/mining.md` first. It has the limits, the repeat rules, the
findings format, and the approval steps. This file adds what is special to sessions.

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

If corrections ask for the same behavior, put them in one group. The words can be different. Then
apply "Repeats" from the reference. A correction is one signal, and a session is one source.

## 3. Write the findings file

Write `~/.ai/<repo>/mined/YYYY-MM-DD-sessions.md` in the format of the reference. Get the dir from
the "mined dir" line of the script. Use these values:

- Title: `# Mined corrections: Claude Code sessions, <date>`
- Counts line: `Sessions: 50 read, 12 not read.`
- IDs: the first 8 characters of the session id.
- Evidence lines, for example:

  ```markdown
  - "use -q, the output is too long" (after: `Bash: ./gradlew build`)
  - Rejected `Bash: ./gradlew test`: "quiet mode"
  ```

  In "Seen once", also give the session id:

  ```markdown
  - "do not open the browser" (`a2788774`, after: `Bash: open index.html`)
  ```

After the file is saved, save the state:

```bash
bash "${CLAUDE_SKILL_DIR}/sessions.sh" save-state
```

## 4. Propose the targets and get approval

Follow "Targets and approval" in the reference.
