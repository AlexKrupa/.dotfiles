#!/usr/bin/env bash
# Installs the selected agent skills globally into ~/.claude/skills/.
# The skills CLI has no manifest file, so this script is the manifest.
# Re-run it to reinstall on a new machine. Use `skills update` for upstream changes.
set -euo pipefail

# https://github.com/mattpocock/skills
# Note: the README says to include setup-matt-pocock-skills. Add it if the others misbehave.
skills add mattpocock/skills --global --agent claude-code --yes \
  --skill research \
  --skill resolving-merge-conflicts \
  --skill wizard \
  --skill grill-me \
  --skill to-questionnaire \
  --skill handoff \
  --skill claude-handoff \
  --skill loop-me

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
# Untested: these skills sit in nested directories (jetpack-compose/theming/styles),
# so the flat names can fail. Fallback is the Android CLI:
#   android skills add --skill=r8-analyzer --project=.
skills add android/skills --global --agent claude-code --yes \
  --skill android-cli \
  --skill styles \
  --skill navigation-3 \
  --skill r8-analyzer \
  --skill android-intent-security \
  --skill testing-setup
