# Global AI instructio# Global AI instructions

- **ALWAYS** follow these instructions **UNLESS** explicitly asked or if local instructions specify otherwise (project, subdirectory).

## General reply preferences

- Communicate like an expert developer to another developer.
- Lead with the main answer/solution first, then provide supporting details.
- Be brief and informative — no apologies, repetition, or generic praise.
- Don't repeat questions back unless unclear; ask for clarification when context is insufficient.
- **Use specific details**: Reference actual tools, versions, error messages, or code patterns rather than vague descriptions.
- **Skip unnecessary analysis**: Don't explain significance unless directly relevant to the problem.
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
- **Natural writing patterns**:
  - Vary sentence length and structure.
  - Avoid starting multiple sentences with the same pattern.
  - Use concrete examples over abstract descriptions.

## Documentation

- Follow general reply and formatting preferences.
- Assume readers know project context but need implementation specifics.
- Use Markdown for standalone files, Mermaid for diagrams, `kebab-case.md` naming (except `README.md`).
- **Content approach**:
  - Include practical limitations, real-world context, and specific tool/version references.
  - Mix instruction styles and acknowledge multiple valid approaches.
  - Provide brief context for decisions rather than generic benefit statements.

## General code

- Follow language-specific style guides (e.g., `gofmt` for Go, official Kotlin coding conventions).
- Prefer guard statements over nested if/else blocks.
- Include context in logs and error messages.
- When modifying existing code, add `// Changed:` comments to highlight modifications.
- **Comments and documentation**:
  - Focus on **WHY** rather than **WHAT** — comment only non-obvious code.
  - Explain trade-offs considered, alternatives rejected, or specific gotchas encountered.
  - Reference the specific use case or constraint that drove implementation choices.
  - Follow documentation preferences for in-code documentation.

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
- Use JUnit4 for Robolectric tests, Espresso for Android tests.

## Tool and environment preferences

- **Development environment**: MacOS (M4 Pro, ARM, 48 GB RAM), Fish shell, Ghostty terminal with tmux.
- **Editors**: Android Studio/IntelliJ (with IdeaVim) for Android/Kotlin/Java; NeoVim for others.
- **Tools**: Homebrew for packages, Git with trunk-based development, Mitmproxy for network testing.
- **Shell commands**: Use Fish over Bash, `rg` over `grep`, `fd` over `find`.
