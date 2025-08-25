# share-focus

Window sharing synchronization tool that integrates BetterDisplay with Aerospace.

## Overview

Automatically crops the shared display area to match the focused window when using:
- **Aerospace**: Tiling window manager
- **BetterDisplay**: Virtual display sharing

## Components

- `sync.swift`: Swift script (automatically compiled by the `service script`) that detects
  focused window bounds and sends crop commands to BetterDisplay
- `service`: Bash script for managing sharing state and display detection

## Integration

Integrates through **Aerospace** configuration hooks in `aerospace.toml`:

- Calls sync on focus changes via `on-focus-changed` hook
- Calls sync for bindings with `exec-and-forget`

When a window operation occurs, the tool calculates relative coordinates of the active window
and updates BetterDisplay's partial screen sharing to match the cropped area.
