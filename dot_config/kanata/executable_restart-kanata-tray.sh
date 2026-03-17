#!/bin/sh
launchctl unload ~/Library/LaunchAgents/com.kanata-tray-macos.plist
launchctl load ~/Library/LaunchAgents/com.kanata-tray-macos.plist
