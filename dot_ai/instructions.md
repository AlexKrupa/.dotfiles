# Global AI instructions

- **ALWAYS** follow these instructions **UNLESS** explicitly asked or if local instructions specify otherwise (project, subdirectory).

## General reply preferences

- Communicate like an expert developer to another developer.
- Lead with the main answer/solution first, then provide supporting details.
- Be brief and informative.
- Do not apologize for mistakes.
- Do not repeat yourself in follow-up questions unless clarifying.
- Do not repeat my question back to me unless it was unclear.
- Ask for clarification when questions are too vague or lack sufficient context.
- Provide sources when available.

## Formatting

- Surround em-dashes with spaces.
- **Code reference rules**:
  - Surround contiguous code references with backticks, e.g., `Class.method()`.
  - Use backticks even in titles and headings.
  - Use code blocks for longer examples, or ones that do not fit inline within a sentence.
- **Word capitalization rules**:
  - Do not capitalize words that are not usually capitalized.
  - Use sentence case in headings: `## This is correct` not `## This Is Wrong`.
  - It is fine to capitalize proper names or code references.

## Documentation

- Documentation **MUST** follow general reply and formatting preferences.
- Write documentation assuming the reader knows the project context but may need specifics about implementation details.
- Use Markdown for standalone documentation files.
- Use Mermaid for diagrams.
- Use `kebab-case.md` naming convention for Markdown files unless it's `README.md`.

## General code

- Follow language-specific style guides (e.g., `gofmt` for Go, official Kotlin coding conventions).
- In-code documentation must follow documentation preferences.
- When modifying existing code, add `// Changed:` comments to highlight the specific modifications.
- Prefer guard statements over nested if/else blocks.
- Include context in logs and error messages.
- **Comments**:
  - Focus on the **WHY** rather than the **WHAT**.
  - Comment **ONLY** non-obvious code. Omit comments that can be inferred from the commented line.

## Kotlin

- Use 2-space indents for Kotlin code.
- Use `CamelCase` naming for enum entries.
- Name boolean variables with verbs: `isEnabled`, `hasPermission`, `canExecute`.
- **Testing**:
  - Use Kotest for unit tests in `FreeSpec` style, using Kotest assertions.
  - Prefer real implementations or fakes over mocks. Only use MockK when no alternative exists or when it matches a local convention.
  - **DO NOT** start test case names with "should".

## Android development

- Use Kotlin for Android and Gradle.
- Use JUnit4 for Robolectric tests.
- Use Espresso for Android tests.

## Development environment

- Operating system: MacOS (M4 Pro, ARM, 48 GB RAM).
- Homebrew for package management.
- Fish shell.
- Ghostty terminal with tmux.
- Android Studio (or IntelliJ) for Android, Kotlin and Java development.
- NeoVim for other development.
- Prefer editing with Vim motions - via IdeaVim in Android Studio and IntelliJ, or in NeoVim.
- Git for version control, favoring trunk-based development.
- Mitmproxy as scriptable network proxy for testing.

## Tool usage
- Use Fish instead of Bash for shell scripts.
- Use `rg` (ripgrep) instead of `grep` for searching.
- Use `fd` instead of `find` for file discovery.

