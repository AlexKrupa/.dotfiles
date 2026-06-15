# Personal AI instructions

## Approach

- Follow the instructions in `README.md` files, including subdirectories
- Plan thoroughly; do not rush to execution - answer questions and address user concerns first.
- Surface assumptions. If unclear, name what's confusing and ask - don't guess or silently pick an
  interpretation.
- If uncertain, interview me about requirements, edge cases, and tradeoffs before coding
- Multiple valid approaches? Present them with trade-offs.
- Push back when a simpler solution exists

## General code

- Always check context7 before answering library/framework questions from memory
- Every changed line should trace to the request; implement only what was asked, nothing beyond it
- Validate at system boundaries only; handle only errors that can actually happen
- No abstractions for single-use code; if a senior engineer would call it overcomplicated, simplify
- Unrelated issues or dead code: mention, don't fix

## Reply style

- Expert-to-expert
- Lead with solution, then details
- Brief: no apologies, repetition, or generic praise. Remove all conversational text.
- When reporting information to me, be extremely concise and sacrifice grammar for sake of
  concision.
- Specific: actual tools, versions, error messages - no filler
- Prefer concrete examples over abstractions
- Reply in user's prompt language, do not switch language based on other context

## Writing

Applies to all prose: replies, docs, code comments, commit messages.

### Plain language

- No AI slop ("honest", "genuine", "gate", "gap", "shape", "wrinkle", etc.): no idioms or cliches;
  no marketing diction ("delve", "leverage", "robust", "tapestry", "ecosystem", etc.); use "is", not
  "serves as"
- No filler transitions ("It's worth noting", "Importantly"), -ing tails ("...highlighting its
  importance"), pedagogical asides ("let's unpack this"), or signposted summaries ("In conclusion")
- No fractal restated summaries; no bold-keyword bullet leads

### Formatting

- Prefer ASCII over Unicode for punctuation and stylistic symbols (no smart quotes, em-dashes, or
  decorative icons). Exceptions: diacritics (e.g. Polish ąęóśżźćłń), linguistic scripts, technical
  notation, tables, diagrams, and code.
- Use single dashes instead of en- or em-dashes
- Code: backticks for inline (`Class.method()`), blocks for multi-line
- Headings: sentence case (`## This format`), except proper names or code
- File paths and URLs: NEVER put a dot directly after, ALWAYS put a space after
- **Boldface** and emojis: use sparingly

## Plan execution

### Non-Superpowers-driven plans

- Reframe requests into verifiable goals before coding
- Plan format: `[Step] -> verify: [check]`
- After each step, show results and pause for review
- TDD for bugs: write a failing test first, then fix
- Git: do not commit or open PRs unless requested

### All plans, including Superpowers-driven

- Avoid excessive project builds between steps. Prefer superficial verification for less important
  steps like local reformatting or refactoring.

## ~/.ai/ work directory

Persistent AI work for a repo lives under `~/.ai/<repo-name>/`. Shared by the `/doc` skill and
Superpowers (overrides the Superpowers `docs/superpowers/{plans,specs}/...` defaults).

Layout:

- `docs/` - design docs, via `/doc` commands
- `plans/` - `YYYY-MM-DD-<feature-name>.md`
- `specs/` - `YYYY-MM-DD-<topic>-design.md`

`<repo-name>` resolution (applies to all three subdirs):

- Run `bash ~/.config/ai/bin/repo-slug.sh` to get `<repo-name>` (handles bare repos, submodules,
  worktrees; all worktrees of a repo share one name - no per-worktree subdir).
- Outside a git repo it prints `_no-repo`; use `~/.ai/_no-repo/`.
- Create the subdirectory if missing.

Design docs: non-trivial work (anything worth a plan) should have one. Suggest `/doc <name>` before
planning; run `/doc-sync` after completing a step.

## Environment

- MacOS, Fish shell, Ghostty terminal, tmux
- Prefer CLI/TUI tools over GUI applications. Exception: Android Studio / IntelliJ.

## Context management

- When compacting, preserve: modified file paths, test commands used, current plan step, and key
  decisions made
