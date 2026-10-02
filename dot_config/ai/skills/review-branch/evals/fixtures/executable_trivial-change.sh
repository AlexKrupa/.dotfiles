#!/usr/bin/env bash
# Usage: trivial-change.sh <repo-dir>
# Branch `chore/release-1.3.0` vs local `main`, no remote (parent-fetched: no).
# Changes: version bump, changelog entry, README typo fix. Nothing to flag.
source "$(dirname "$0")/lib.sh"
init_repo "$1"

put README.md <<'EOF'
# Greeter

Instal the app with `./gradlew installDist`.
EOF

put CHANGELOG.md <<'EOF'
# Changelog

## 1.2.0

- Add greeting by name.
EOF

put build.gradle.kts <<'EOF'
plugins {
    kotlin("jvm") version "2.0.21"
    application
}

version = "1.2.0"

application {
    mainClass = "AppKt"
}
EOF

put src/main/kotlin/App.kt <<'EOF'
fun greet(name: String): String = "Hello, $name!"

fun main(args: Array<String>) {
    println(greet(args.firstOrNull() ?: "world"))
}
EOF

commit "Initial greeter"

git switch -q -c chore/release-1.3.0
sed -i '' 's/^Instal the app/Install the app/' README.md
sed -i '' 's/^version = "1.2.0"/version = "1.3.0"/' build.gradle.kts
put CHANGELOG.md <<'EOF'
# Changelog

## 1.3.0

- Fix a typo in the README.

## 1.2.0

- Add greeting by name.
EOF
commit "Release 1.3.0"
