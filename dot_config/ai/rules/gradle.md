---
paths:
  - "**/{build,settings}.gradle*"
---

- Run Gradle commands in quiet mode (`-q`), unless output is needed for debugging
- Preserve build cache and configuration cache compatibility:
  - No non-deterministic task inputs/outputs (timestamps, absolute paths, random values)
  - At configuration time, use `providers` APIs (e.g., `providers.fileContents()`,
    `providers.systemProperty()`, `providers.environmentVariable()`, `providers.gradleProperty()`)
    instead of direct reads (e.g. `System.getProperty()`, `System.getenv()`, `File.readText()`)
  - Use lazy APIs: `tasks.register` (not `create`), `tasks.named` (not `getByName`),
    `configureEach {}` (not `all {}`)
  - Wire task inputs/outputs directly (`inputFiles.from(otherTask.flatMap { it.outputFile })`)
    instead of `dependsOn` + hardcoded paths
- Use `layout.buildDirectory` instead of deprecated `project.buildDir`
- Apply plugins via `plugins {}` block, not `apply plugin:`
