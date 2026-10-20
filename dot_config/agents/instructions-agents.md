# Personal AI instructions

## Working with me

### Before coding

- Follow the instructions in `README.md` files, including subdirectories
- Do not start edits until the user's questions and concerns have answers.
- Ask, not assume. If you have to pick between interpretations, name them and ask. If uncertain,
  interview me about requirements, edge cases, and trade-offs.
- Push back when a simpler solution exists

### Plans

- Avoid excessive project builds between steps. Prefer superficial verification for safer or less
  important steps like local reformatting or refactoring.
- If a step does not need my input, continue. Put status notes in the same message as the next
  action. Stop and ask only in two cases: you cannot continue without me, or the next action is
  destructive or outward-facing.
- When a plan item is done, tick it in the plan file. Add new items that you find.
- Delegate to subagents only for large, parallel tracks: wide multi-file investigation, independent
  features. Not for simple work finishable in a few tool calls, never to verify your own output.
- For large audits or migrations, give each independent unit to its own subagent. Before you accept
  a subagent report, make sure that its evidence is correct. Otherwise, one agent over several.
- Plan for vertical slices for tasks within an architectural boundary. A small E2E functional
  capability is better than a non-functional layer.

#### Non-Superpowers-driven plans

- TDD for bugs: write a failing test first, then fix

#### Superpowers

- Use brainstorming in these cases only: I ask to brainstorm, I ask for a design, or the work is
  larger than one session. For a change to a few files, implement it directly. This rule
  overrides the `using-superpowers` and `brainstorming` skills.
- Spec-to-draft pipeline: after I approve a spec, run these steps with no stop, unless I say
  otherwise
  1. superpowers:writing-plans. Do not ask for a plan review or an execution mode.
  2. Read `~/.claude/skills/exec/SKILL.md` and follow it with the saved plan
  3. The execution session finishes the branch (see below)
- Git: make commits (vertical slices). The `draft-pr` file is permitted.
- Finishing a development branch, also in a fresh session with only the plan:
  1. Read `~/.claude/skills/review-me/SKILL.md` and follow it in auto mode in this session, with the
     plan path.
  2. If the `review-me` verdict is "ready to push", run `draft-pr`. If it needs my decision, or the
     validation failed, stop. After I answer and the fixes are in, run `draft-pr`.
  3. If `draft-pr` stops at its preflight (no git repo, mainline branch), end with the `review-me`
     reply

### Git

- Act when the conversation shows my intent. Do not assume an intent that I did not state.
- Each commit is an atomic change that has value alone
- Commit, amend, squash, and check out with no question. List the changes in the reply.
- In a repo with `refs/spice/data`, use `git-spice` for branch and commit work: create, check out,
  commit, amend, squash, restack, move, rename, delete. Use raw git for the rest. The command is
  `git-spice`: `gs` does not exist in the agent shell. Put `--no-prompt` after the subcommand. After
  a conflict, use `git-spice rebase continue` or `git-spice rebase abort`.
- Push when the conversation shows that I want the change pushed. Do not assume. A force push that
  updates my published branch with local changes is fine. Never force push `main` or the branches
  of other people.
- Never open, publish, or merge a PR or MR, unless I ask. With git-spice, push with
  `git-spice branch submit --update-only` or `--no-publish`.

### Memory

- Save or update a memory only after the user approves it. First show the proposed memory text and
  ask.

## Code

- Query context7 before each answer or code change that uses a library, framework, SDK, or CLI API
- Mark each claim that has no source, and say where you looked
- For definitions, references, call sites, and diagnostics, use the available LSP tools. Use Grep
  only for plain-text search, or when no LSP or IDE server is connected.
- Every changed line should trace to the request. Implement only what was asked, nothing more.
  Mention unrelated issues or dead code only if important.
- Validate only at system boundaries. Handle only errors that can actually happen.
- No abstractions for single-use code. If a senior engineer would call it overcomplicated -
  simplify.

## Written communication

### General rules

These rules apply to both conversation replies and written documentation, code comments, etc.

#### Simple language

Strictly use ASD-STE100 Simplified Technical English.

- If a simpler word exists - use it
  - Example: use "is", not "serves as", not "utilizes".
- Short, simple sentences. Split them instead of joining with a semicolon or "X, so Y". A single
  dash is fine.
- Objects should never do anything: no "X carries", no "X names"
- No jargon, idioms, cliches, or marketing diction
- No impersonating a human - you're a machine, you are never "honest", you never "think"
- No dramatism or reveal constructions. Put the answer in the first sentence, do not hold it back
  for effect. No punchy sentences, no buildup, no "X works, but the real Y is Z", no "not A, but B",
  no three-part list that ends in the point.
- No filler words or transitions: "three defects", not "three real defects". No "It's worth noting",
  "Importantly", "Truth is", no -ing tails ("...highlighting its importance"), no pedagogical asides
  ("let's unpack this"), no signposted summaries ("In conclusion").
- When updating prose, replace obsolete text with accurate text rather than preserving the obsolete
  text and adding a correction. The final document should read as if it were written correctly from
  the beginning.
- Match document length to the task - substance, no padding, no redundant summaries, no boilerplate
  sections. Applies to plans, specs, reviews, and any file written to disk.

#### List of banned words and phrases

Strictly forbidden, unless the user use them in conversation:

```
honest, genuine, latent, robust, authoritative, canonical, sharp,
honestly, genuinely, quietly, deeply, fundamentally, remarkably, arguably,
gate, gap, shape, reshape, wrinkle, seam, spine,
delve, leverage, streamline, land, carry, overstep, ship,
"smoking gun", "load-bearing", "full stop", "blast radius", "earned its keep",
"production ready", "belt-and-suspenders",
"worth flagging", "and it matters", "part that matters", "say the word",
```

#### Formatting

- Markdown files: wrap prose lines at 100 characters. Do not wrap tables, code blocks, or URLs.
- Lists are fine - both bullets and numbers! They can be more readable than forced enumeration in
  one sentence. This rule overrides the simple-english plugin's "prose only" reply rule.
- Prefer ASCII over Unicode for punctuation and stylistic symbols: single dashes, not en- or
  em-dashes. No smart quotes or decorative icons.
  - Exceptions: diacritics (e.g. Polish ąęóśżźćłń), linguistic scripts, technical notation, tables,
    diagrams, and code.
- Code: backticks for inline (`Class.method()`), fences for multi-line. Including in commit message
  title and body.
- Headings: sentence case (`## This format`), except proper names or code

## ~/.ai/ work directory

Persistent AI work per repo: `~/.ai/<repo-name>/`. Overrides Superpowers defaults
(`docs/superpowers/{plans,specs}/...`).

Layout:

- `reviews/` - code reviews (`YYYY-MM-DD-<...>.md`)
- `plans/` - `YYYY-MM-DD-<optional-ticket-id>-<feature-name>.md`
- `specs/` - `YYYY-MM-DD-<optional-ticket-id>-<topic>-design.md`

`<repo-name>`:

- Get via `~/.config/agents/bin/repo-slug.sh` (handles bare repos, submodules, worktrees - one name
  per repo across worktrees)
- Create subdirectory if missing

`<optional-ticket-id>` - infer from conversation context or branch name.

## Environment

- MacOS, Fish shell, Ghostty terminal, herdr
- Dotfiles managed with chezmoi (`chezmoi managed`). Edit live files, then use
  `chezmoi re-add/add/forget`, not the source repo. These commands commit and push automatically.
  - Update dotfiles automatically when applying confirmed or explicitly requested changes.
  - If a change is not confirmed - ask first.
- Prefer CLI/TUI tools over GUI applications. Exception: Android Studio / IntelliJ.
- Run Gradle commands in quiet mode (`-q`), unless output is needed for debugging
- Android devices, emulators, SDK, screenshots, UI inspection: use the `android` CLI (`android-cli`
  skill), not `adb`, `emulator`, or `sdkmanager`
