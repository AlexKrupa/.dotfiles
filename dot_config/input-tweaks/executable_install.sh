#!/usr/bin/env bash
# Builds input-tweaks and installs the launchd agent that starts it at login
set -euo pipefail

cd "$(dirname "$0")"
name=input-tweaks
label=local.$name
binary=$HOME/.local/bin/$name
agent=$HOME/Library/LaunchAgents/$label.plist
domain=gui/$(id -u)

# A rebuild changes the ad-hoc signature, and macOS then drops the Accessibility permission
if [[ main.swift -nt $binary ]]; then
    mkdir -p "$(dirname "$binary")"
    swiftc -O main.swift -o "$binary"
    echo "Built $binary. Give it Accessibility permission when macOS asks."
fi

mkdir -p "$(dirname "$agent")"
sed -e "s|@BINARY@|$binary|" -e "s|@LABEL@|$label|g" launch-agent.plist > "$agent"
launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$agent"
echo "Started $label. Log: /tmp/$label.log"
