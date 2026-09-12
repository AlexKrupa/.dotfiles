initscript {
  repositories {
    gradlePluginPortal()
  }
  dependencies {
    classpath("com.adarshr:gradle-test-logger-plugin:4.0.0")
  }
}

gradle.lifecycle.beforeProject {
  val project = this
  pluginManager.withPlugin("java") {
    project.plugins.apply(com.adarshr.gradle.testlogger.TestLoggerPlugin::class.java)
    project.extensions.configure<com.adarshr.gradle.testlogger.TestLoggerExtension> {
      showExceptions = true
      showStackTraces = true
      showFullStackTraces = false
      showCauses = true
      slowThreshold = 1000
      showSummary = true
      showSimpleNames = true
      showPassed = false
      showSkipped = false
      showFailed = true
      showStandardStreams = false
      showPassedStandardStreams = true
      showSkippedStandardStreams = true
      showFailedStandardStreams = true
      logLevel = LogLevel.LIFECYCLE
    }
    project.tasks.withType<Test>().configureEach {
      maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).coerceAtLeast(1)
    }
  }
}
