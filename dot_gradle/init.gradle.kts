initscript {
    repositories {
        gradlePluginPortal()
    }
    dependencies {
        classpath("com.adarshr:gradle-test-logger-plugin:4.0.0")
    }
}

allprojects {
    afterEvaluate {
        if (!plugins.hasPlugin("com.adarshr.gradle.testlogger")) {
            apply<com.adarshr.gradle.testlogger.TestLoggerPlugin>()
        }
        configure<com.adarshr.gradle.testlogger.TestLoggerExtension> {
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
            // showOnlySlow = false
            showStandardStreams = false
            showPassedStandardStreams = true
            showSkippedStandardStreams = true
            showFailedStandardStreams = true
            logLevel = LogLevel.LIFECYCLE
        }
    }
}

gradle.afterProject {
    tasks.withType<Test> {
        maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).takeIf { it > 0 } ?: 1
    }
}

