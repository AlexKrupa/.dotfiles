#!/usr/bin/env bash
set -euo pipefail

label=local.input-tweaks
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/input-tweaks"
