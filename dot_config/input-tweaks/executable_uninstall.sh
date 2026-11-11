#!/usr/bin/env bash
# Stops input-tweaks and removes the binary and the launchd agent
set -euo pipefail

label=local.input-tweaks
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/input-tweaks"
