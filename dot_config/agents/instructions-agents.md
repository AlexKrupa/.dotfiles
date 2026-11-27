# Personal AI instructions

## Working with me

### Before coding

- Follow the instructions in `README.md` files, including subdirectories
- Follow the documentation in any `docs/` or similar directories
- Do not start edits until the user's questions and concerns have answers.
- Ask, not assume. If you have to pick between interpretations, name them and ask. If uncertain,
  interview me about requirements, edge cases, and trade-offs.
  - Do not ask about the obvious follow-through of a decided change: the tests, docs, and README of
    the changed code. Do it, and list it in the reply.
- If the options of a question differ in code or UI, show a short snippet or mockup for each.
- Push back when a simpler solution exists
- A "why" question is not disagreement. Explain the reason. Change a recommendation only for a new
  fact or an error in your reasoning, and name it.

### Plans

- Avoid excessive project builds between steps. Prefer superficial verification for safer or less
  important steps like local reformatting or refactoring.
- CI is the broad test. Locally, run only the tests of the changed code. After a CI failure, run
  only the failed tests, not the full suite.
- If a step does not need my input, continue. Do not stop for a status note. Stop and ask only in
  two cases: you cannot continue without me, or the next action is destructive or outward-facing.
- Delegate to subagents only for large, parallel tracks: wide multi-file investigation, independent
  features. Not for simple work finishable in a few tool calls, never to verify your own output.
- For large audits or migrations, give each independent unit to its own subagent. Before you accept
  a subagent report, make sure that its evidence is correct. Otherwise, one agent over several.
- Plan for vertical slices for tasks within an architectural boundary. A small E2E functional
  capability is better than a non-functional layer.

#### Non-Superpowers-driven plans

- TDD for bugs: write a failing test first, then fix

#### Superpowers

- Use `superpowers:brainstorming` in these cases only: I ask to brainstorm, I ask for a design, or
  the work is larger than one session. For a change to a few files, implement it directly. This rule
  overrides the `superpowers:using-superpowers` and `superpowers:brainstorming` skills.
- Spec-to-draft pipeline: after I approve the design in the conversation, run these steps with no
  stop, unless I say otherwise. This rule overrides the spec review gate and the "No spec file" rule
  of `superpowers:brainstorming`.
  1. Save the spec. On the bounded path, the spec is short: goal, approach, files, tests. Do not ask
     me to review it. Ask only about content that the conversation did not agree on.
  2. Architectural path:
     1. `superpowers:writing-plans`. Do not ask for a plan review or an execution mode.
     2. Read `~/.config/agents/skills/exec/SKILL.md` and follow it with the saved plan
     3. `exec` does the review and the PR draft
  3. Bounded path:
     1. Implement the spec with commits, with no plan
     2. Read `~/.config/agents/skills/review-me/SKILL.md` and follow it in auto mode with the spec
        path
     3. Follow the `draft-pr` step of `~/.config/agents/skills/exec/review.md` for the PR draft
- Git: make commits (vertical slices). The `draft-pr` file is permitted.
- After the last task of a plan execution, in place of the final review and
  `superpowers:finishing-a-development-branch`: read `~/.config/agents/skills/exec/SKILL.md`,
  section "Review handoff", and follow it

### Shorthand

When my message starts with one of these phrases, do the action. Then read the rest of the message.

- `tldr` - your last reply is too long. Write it again: the answer first, only the facts that I
  need, no new content.
- `go`, `go ahead`, `continue` - do the next action that you proposed. Do not ask again.
- `done` - I did the step that you gave me. Make sure that the result is correct, then continue.
- `commit this` - commit the changes of this conversation as atomic commits. Do not push.
- `push`, `update MR` - I permit a push. If the branch is part of a stack, push all branches of the
  stack. Follow the push rules in `### Git`.
- `fix nits`, `fix minors`, `fix majors`, `fix criticals` - fix the findings of the last review at
  one level: nit is `low`, minor is `medium`, major is `high`, critical is `critical`.
- `squash fixups`, `squash branch` - find the repair commits of the branch in the same way that
  `review-me` does. Then run
  `~/.config/agents/bin/git-squash-fixups.sh <parent> <repair>:<target>...`. It also squashes the
  `fixup!` and `amend!` commits.

### Git

- Act when the conversation shows my intent. Do not assume an intent that I did not state.
- Each commit is an atomic change that has value alone
- When I ask for a commit, or a plan or skill tells you to commit, commit, amend, squash, and check
  out with no question. List the changes in the reply.
- When possible, use `git-spice` for branch and commit work: create, check out, commit, amend,
  squash, restack, move, rename, delete. Use raw git for the rest. The command is `git-spice`: `gs`
  does not exist in the agent shell. Put `--no-prompt` after the subcommand. After a conflict, use
  `git-spice rebase continue` or `git-spice rebase abort`. Create a branch with
  `git-spice branch create`, not `git switch -c <name> origin/<branch>`: that command makes the
  remote branch the upstream.
- If the repo has no `refs/spice/data`, run
  `git-spice repo init --trunk <default-branch> --no-prompt` before the first git-spice command.
  Without it, git-spice cannot find the trunk.
- If the branch is part of a stack, use `git-spice stack` commands, not `git-spice branch` commands.
  Only `stack` commands update the stack comment in each PR or MR.
- Push when the conversation shows that I want the change pushed. Do not assume. A force push that
  updates my published branch with local changes is fine. Never force push `main` or the branches of
  other people.
- Never open, publish, or merge a PR or MR, unless I ask. With git-spice, push with
  `submit --update-only` or `submit --no-publish`.
- Before each `submit`, run `git-spice repo sync --no-prompt` and
  `git-spice stack restack --no-prompt`. Other sessions move the shared local trunk, and git-spice
  does not submit a branch that needs a restack.

### Memory

- Save or update a memory only after the user approves it. First show the proposed memory text and
  ask.

## Code

- Do not rely on training data for the API of a library, framework, or SDK. In these cases, query
  context7 before an answer or a code change that uses the API:
  - This session and the project code do not show the API.
  - The version is different from your training data.
  - A call fails or acts unexpectedly.
- Before you use a flag or subcommand of an installed CLI for the first time in a session, read
  `<tool> --help` or `man <tool>`. Exception: basic shell, coreutils, and everyday git commands.
- Mark each claim that has no source with 🔮. If I ask, say where you looked.
- For definitions, references, call sites, hover types, and diagnostics, use the `LSP` tool before
  Grep, for example in Kotlin code.
  - `LSP` is a deferred tool. Load it with `ToolSearch` (`select:LSP`) before the first use.
  - Grep is the fallback for three cases only: plain-text search, no `LSP` tool, or an empty LSP
    result after indexing is done.
- To read the source of a third-party Gradle dependency, use the `ksrc` MCP tools (`search`, `cat`,
  `deps`), not files in `~/.gradle`
- Every changed line traces to the request. Implement only what was asked, nothing more. Mention
  unrelated issues or dead code only if important.
- Validate only at system boundaries. Handle only errors that can actually happen.
- No abstractions for single-use code. If a senior engineer calls it overcomplicated, simplify it.

### Design

- Prefer deep modules: a small interface that hides much functionality. A shallow module, with an
  interface as complex as its body, adds cost and no value.
- Hide each design decision in one module. If a change to one decision needs edits in several
  modules, the decision leaks.
- No pass-through methods and no wrappers that only forward calls with the same signature.
- Define errors out of existence: design the API so that the error case cannot occur. For example, a
  delete of a missing key does nothing.
- Each layer has a different abstraction from the layers above and below it.

### Style

- Match existing code style, not your preference
- Formatting follows the "rectangle rule": "each subtree gets its own bounding rectangle, containing
  all of that subtree's text and none of any other subtree’s"

### Control flow

- Guard clauses over nested conditionals
- Prefer positive invariants, not negated conditions
  - `if (index < size) { holds } else { doesn't }`, not `if (index >= size)`
- Push ifs up - hoist branching to the caller, keep helpers branch-free on that condition
- Push fors down - push loops into the function owning the collection, pass whole collections, not
  elements
- Match enum/sealed hierarchies exhaustively (no catch-all `else`/`default`) so a new variant fails
  at compile time instead of silently falling through

### Naming

- Avoid abbreviations, unless very local or obvious from domain context and they aid readability
- Prefer paired names of equal length so call sites align (`source`/`target`, not `src`/`dest`). Do
  not force it when equal length is not natural

### Comments (inline and doc)

- Comment only when the code cannot show the reason, or when the user asks for a comment
  - Exception: if a doc comment on an interface says something that the signature does not, the
    comment is fine
- Comment what is there, not the diff
  - No conversation-specific context, nothing about what changed, no "now handles", no "previously"
- Are extremely concise and only provide relevant information
- Explain WHY, not WHAT
- A comment to generic code must not reference specific callers or cases

### Other

- Declare variables at the smallest scope, close to first use. Do not hoist early or alias
- Include context in logs and error messages
- Only clean up things your changes made unused
- Numbers:
  - Keep index (0-based), count (1-based), and size (units) distinct
  - Put the unit in the name (`rowIndex`, `rowCount`, `sizeBytes`)
  - Make rounding explicit at the call site (ceil- vs floor-div)

### Tests

- Test doubles: prefer real implementations or fakes over mocks
- Test names: active voice, 3rd person, never start with "should"
- Test body: visually separate setup/action/assertion in longer tests, but without section comments
- Test class/spec structure: read top-to-bottom - put setup and relevant context (private methods)
  before the tests
- Avoid change-detector tests
- Prefer wider test scope when it covers more real code at the same branch count

## Written communication

### General rules

These rules apply to both conversation replies and written documentation, code comments, etc.

#### Simple language

Follow the simple-english rules in Plain mode. Do not use Strict mode.

- If a simpler word exists - use it
  - Example: use "is", not "serves as", not "utilizes".
- Short, simple sentences. Split them instead of joining with a semicolon or "X, so Y". A single
  dash is fine.
- No metaphor verbs for objects: no "X names", no "X owns". Use a verb for a real action: "the
  script deletes".
- No jargon, idioms, cliches, or marketing diction
- No impersonating a human - you are a machine, you are never "honest", you never "think"
- No dramatism or reveal constructions. Put the answer in the first sentence, do not hold it back
  for effect. No punchy sentences, no buildup, no "X works, but the real Y is Z", no "not A, but B",
  no three-part list that ends in the point.
- No filler words or transitions: "three defects", not "three real defects". No "It's worth noting",
  "Importantly", "Truth is", no -ing tails ("...highlighting its importance"), no pedagogical asides
  ("let's unpack this"), no signposted summaries ("In conclusion").
- When updating prose, replace obsolete text with accurate text rather than preserving the obsolete
  text and adding a correction. Write the final document as if it was correct from the beginning.
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
- Markdown renderers join lines with a single line break into one line. For a new line, put a blank
  line between the lines, or make each line a list item. Use a list for items of the same kind, for
  example links or findings.
- Structure over prose, in replies and in files. Pick the format from the content:
  - Table: 3 or more items that share 2 or more attributes, for example options, scenarios, or
    before and after
  - Headings: 2 or more topics, or a reply longer than one screen
  - List: 3 or more parallel items or steps. Each item is at most 2 short sentences.
  - Prose: one fact, one decision, or one reason. At most 3 sentences per paragraph.
- These rules override the simple-english reply rules "prose only", "no headers", "no bullet lists",
  and "no tables". All other simple-english rules apply.
- Prefer ASCII over Unicode for punctuation and stylistic symbols: single dashes, not en- or
  em-dashes. No smart quotes.
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

- MacOS, Ghostty terminal, herdr
- Shells:
  - My terminal shell is Fish. Use Fish syntax for commands that I run in my own terminal.
  - The Bash tool and the `! <command>` prompt prefix run zsh. Use zsh syntax for them, also when
    you give me a `! <command>` to type.
- Dotfiles: see `~/.config/agents/machine.md`. chezmoi makes it for each machine.
- A disabled plugin, MCP server, or similar entry in a user-level `settings.json` is not unused. I
  enable it per project. If an item is not clearly unused, ask me before you call it unused or
  remove it.
- Prefer CLI/TUI tools over GUI applications. Exception: Android Studio / IntelliJ.
- Run Gradle commands in quiet mode (`-q`), unless output is needed for debugging
- Android devices, emulators, SDK, screenshots, UI inspection: use the `android` CLI (`android-cli`
  skill), not `adb`, `emulator`, or `sdkmanager`
- After a change to Compose UI: render and examine it with the `android-compose-preview` skill
