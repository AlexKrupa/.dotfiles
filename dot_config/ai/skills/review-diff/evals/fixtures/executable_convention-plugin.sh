#!/usr/bin/env bash
# Usage: convention-plugin.sh <repo-dir>
# Branch `feat/analytics` vs `main` (with origin). Gradle with a build-logic convention plugin.
# Structure change (expect a module diagram):
#   new module :core:analytics
#   build-logic `shop.feature` plugin adds implementation(project(":core:analytics")) - this
#   gives a new edge from every module that applies the plugin: :feature:cart, :feature:checkout,
#   :feature:search, :feature:profile. :core:ui uses `shop.library` and gets no edge.
# No build.gradle.kts of a feature module changes.
source "$(dirname "$0")/../../../../evals/fixture-lib.sh"
init_repo "$1"

put settings.gradle.kts <<'EOF'
pluginManagement {
    includeBuild("build-logic")
}
rootProject.name = "shop"
include(":app")
include(":feature:cart", ":feature:checkout", ":feature:search", ":feature:profile")
include(":core:ui", ":core:network")
EOF

put build-logic/convention/build.gradle.kts <<'EOF'
plugins {
    `kotlin-dsl`
}

gradlePlugin {
    plugins {
        register("feature") {
            id = "shop.feature"
            implementationClass = "FeatureConventionPlugin"
        }
        register("library") {
            id = "shop.library"
            implementationClass = "LibraryConventionPlugin"
        }
    }
}
EOF

put build-logic/convention/src/main/kotlin/FeatureConventionPlugin.kt <<'EOF'
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies

class FeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("shop.library")
        dependencies {
            add("implementation", project(":core:ui"))
            add("implementation", project(":core:network"))
        }
    }
}
EOF

put build-logic/convention/src/main/kotlin/LibraryConventionPlugin.kt <<'EOF'
import org.gradle.api.Plugin
import org.gradle.api.Project

class LibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("org.jetbrains.kotlin.jvm")
    }
}
EOF

for f in cart checkout search profile; do
  put "feature/$f/build.gradle.kts" <<'EOF'
plugins {
    id("shop.feature")
}
EOF
done

for c in ui network; do
  put "core/$c/build.gradle.kts" <<'EOF'
plugins {
    id("shop.library")
}
EOF
done

put app/build.gradle.kts <<'EOF'
plugins {
    kotlin("jvm")
}

dependencies {
    implementation(project(":feature:cart"))
    implementation(project(":feature:checkout"))
    implementation(project(":feature:search"))
    implementation(project(":feature:profile"))
}
EOF

commit "Initial shop modules with convention plugins"
add_origin

git switch -q -c feat/analytics

sed -i '' 's/include(":core:ui", ":core:network")/include(":core:ui", ":core:network", ":core:analytics")/' settings.gradle.kts

put core/analytics/build.gradle.kts <<'EOF'
plugins {
    id("shop.library")
}
EOF

put core/analytics/src/main/kotlin/shop/analytics/Analytics.kt <<'EOF'
package shop.analytics

object Analytics {
    private val events = mutableListOf<String>()

    fun track(name: String) {
        events += name
    }
}
EOF

put build-logic/convention/src/main/kotlin/FeatureConventionPlugin.kt <<'EOF'
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.dependencies

class FeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("shop.library")
        dependencies {
            add("implementation", project(":core:ui"))
            add("implementation", project(":core:network"))
            add("implementation", project(":core:analytics"))
        }
    }
}
EOF

commit "Give every feature module the analytics module"
