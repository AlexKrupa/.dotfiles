#!/usr/bin/env bash
# Installs the selected agent skills globally into ~/.claude/skills/.
# The skills CLI has no manifest file, so this script is the manifest.
# Re-run it to reinstall on a new machine. Use `skills update` for upstream changes.
set -euo pipefail

# https://github.com/mattpocock/skills
# grill-me only calls grilling.
skills add mattpocock/skills --global --agent claude-code --yes \
  --skill grilling \
  --skill grill-me

# https://github.com/chrisbanes/skills
skills add chrisbanes/skills --global --agent claude-code --yes \
  --skill kotlin-api-design \
  --skill kotlin-concurrency-and-flow \
  --skill kotlin-control-flow \
  --skill compose-animations \
  --skill compose-component-design \
  --skill compose-focus-navigation \
  --skill compose-performance \
  --skill compose-state-and-effects \
  --skill compose-ui-testing-patterns

# https://github.com/android/skills
# Untested: these skills are in nested directories (jetpack-compose/theming/styles). The flat
# names can fail. The fallback is the Android CLI:
#   android skills add --skill=r8-analyzer --project=.
skills add android/skills --global --agent claude-code --yes \
  --skill android-cli \
  --skill styles \
  --skill navigation-3 \
  --skill r8-analyzer \
  --skill android-intent-security \
  --skill testing-setup

# https://github.com/gradle/gradle-skills
skills add gradle/gradle-skills --global --agent claude-code --yes \
  --skill gradle-best-practices \
  --skill gradle-wrapper-upgrade
