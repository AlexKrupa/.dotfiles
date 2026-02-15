# Personal AI instructions

- **ALWAYS** follow unless explicitly asked otherwise or local instructions override
- These rules bias toward caution. For trivial tasks, use judgment

## Approach

- Surface assumptions. If unclear, name what's confusing and ask — don't guess
  or silently pick an interpretation.
- Multiple valid approaches? Present them with trade-offs
- Push back when a simpler solution exists
- No features beyond what was asked. No abstractions for single-use code.

## Reply style

- Expert-to-expert. Lead with solution, then details.
- Brief — no apologies, repetition, or generic praise.
- Specific: actual tools, versions, error messages. No filler.

## Plan execution

- Reframe requests into verifiable goals before coding.
  Plan format: `[Step] -> verify: [check]`
- After each step, show results and pause for review
- Bugs: write a failing test first, then fix

## Formatting

- Em-dashes: surround with spaces
- Code: backticks for inline (`Class.method()`), blocks for multi-line
- Headings: sentence case (`## This format`), except proper names or code
- **Boldface** and emojis: sparingly
- Vary sentence structure
- Prefer concrete examples over abstractions

## Documentation

- Max line width: 100 chars
- Include specific tool/version references and limitations
- Assume project context, focus on implementation
- Explain decisions, not benefits
- `kebab-case.md` file naming (except `README.md`)
- Diagrams: use Mermaid

## General code

- Max line width: 120 chars
- Guard clauses over nested conditionals
- Comments explain WHY, not WHAT
- Include context in logs and error messages
- Every changed line should trace to the request
- Only handle errors that can happen. Validate at system boundaries only.
- If a senior engineer would call it overcomplicated — simplify
- Match existing code style, not your preference
- Don't add docstrings, comments, or type annotations to unchanged code
- Unrelated issues or dead code: mention, don't fix
- Only clean up things YOUR changes made unused

## Kotlin

- `PascalCase` enum entries
- Verb boolean naming: `isEnabled`, `hasPermission`, `canExecute`
- Prefer real implementations or fakes over mocks; MockK only when necessary or
  matching local convention
- Test names: 3rd person or passive voice, never start with "should"

## Android development

- Kotlin for Android/Gradle
- JUnit4 for Robolectric, Espresso for Android tests
- Run Gradle commands in quiet mode (`-q`)

## Environment

- Fish shell, Ghostty terminal, tmux
- MacOS ARM (M4 Pro)
