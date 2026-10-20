---
name: gradle
description: 'Use when writing or changing Gradle build scripts, that is, build, settings, or init files that end in `.gradle` or `.gradle.kts`: build cache, configuration cache, `providers` APIs, lazy task APIs, convention plugins, or the `plugins {}` block.'
---

# Gradle

Rules that keep Gradle builds compatible with the build cache and the configuration cache.

- Preserve build cache and configuration cache compatibility:
  - No non-deterministic task inputs/outputs (timestamps, absolute paths, random values)
  - At configuration time, use `providers` APIs (e.g., `providers.fileContents()`,
    `providers.systemProperty()`, `providers.environmentVariable()`, `providers.gradleProperty()`)
    instead of direct reads (e.g. `System.getProperty()`, `System.getenv()`, `File.readText()`)
  - Use lazy APIs: `tasks.register` (not `create`), `tasks.named` (not `getByName`),
    `configureEach {}` (not `all {}`)
  - Wire task inputs/outputs directly (`inputFiles.from(otherTask.flatMap { it.outputFile })`)
    instead of `dependsOn` + hardcoded paths
- Prefer convention plugins applied per-project over cross-project configuration (`allprojects`,
  `subprojects`)
- Use `layout.buildDirectory` instead of deprecated `project.buildDir`
- Apply plugins via `plugins {}` block, not `apply plugin:`
