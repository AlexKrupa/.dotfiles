# share-focus

Crops a BetterDisplay virtual display stream to match the currently focused window. Instead of sharing the whole screen, only the active window region is visible.

Requires **Aerospace** (tiling WM) and **BetterDisplay** (virtual display). The `share-focus` binary needs macOS accessibility permissions on first run (System Settings > Privacy & Security > Accessibility).

## Architecture

Two components, no build system:

- `share-focus.swift` - Swift binary with two modes. Default (no args): reads the focused window's bounds via Accessibility APIs, computes relative coordinates, and calls BetterDisplay CLI to update the partial screen crop. With `--watch`: runs as a daemon that detects window drag completion via CGEventTap (monitors `leftMouseDragged` + `leftMouseUp` events, triggers sync with 50ms debounce). Compiled to `share-focus` binary by the `service` script on first run. PID stored in `.cache/watcher.pid` when running in watch mode.
- `service` - Bash script that manages sharing lifecycle: detects the main display, creates/connects a BetterDisplay virtual display named "Sharing", writes display info to `.cache/sharing-enabled`, starts the watcher daemon, and toggles sharing on/off.

Data flow: `service start` writes `DisplayName|width height` to `.cache/sharing-enabled`. `share-focus` reads that file, gets the focused window bounds via `kAXFocusedWindowAttribute`, converts to relative coordinates (0.0-1.0), and calls `BetterDisplay set -stream -partialOriginX/Y/Width/Height`. Sync is triggered by Aerospace hooks (focus changes, keyboard moves) and by the watch daemon (mouse drags).

## Usage

```bash
# Toggle sharing on/off
./service

# Explicit start/stop/restart
./service start [--aspect W:H] [--downscale N] [--delay MS] [--preview]
./service stop
./service restart [--aspect W:H] [--downscale N] [--delay MS] [--preview]
./service status

# Toggle preview window while sharing is active
./service preview

# Examples
./service start                      # 16:9 at half resolution (e.g. 1920x1080)
./service start --preview            # same, with floating preview window
./service start --downscale 1        # 16:9 at full 4K resolution
./service start --aspect 4:3         # 4:3 at half resolution
./service start --delay 25           # 25ms delay before reading window bounds

# Run sync manually (only works when sharing is enabled)
./share-focus

# Recompile after editing Swift source
swiftc share-focus.swift -o share-focus
```

`--aspect` sets the virtual display aspect ratio (default: `16:9`). `--downscale` divides the resolution by N (default: `2`). `--delay` adds a sleep in milliseconds before reading window bounds, giving Aerospace time to finish the focus transition (default: `0`). `--preview` opens a floating preview window.

## Aerospace integration

Integrates through Aerospace configuration hooks in `aerospace.toml`:

- `on-focus-changed` calls `share-focus` on every focus change
- `exec-and-forget` calls `share-focus` for window-moving bindings

## Key details

- `share-focus` exits silently (exit 0) when sharing is disabled or window bounds can't be read - this is intentional since it's called on every focus change.
- BetterDisplay CLI path is hardcoded to `/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay`.
- Only `AXStandardWindow` subrole windows are tracked - dialogs, banners, and other window types are ignored.
- Window coordinates are clamped to the display bounds before converting to relative values, so windows at screen edges don't produce out-of-range crop regions.
- The watch daemon fires sync on any mouseUp after a drag (including text selection, file drags, etc.). This is harmless since sync is idempotent and fast.

## Known limitations

- Display resolution is captured once at `service start` and cached in `.cache/sharing-enabled`. If the resolution changes while sharing is active (display reconnect, clamshell mode, scaled resolution change), all crop coordinates will be wrong. Restart sharing (`./service stop && ./service start`) to pick up the new resolution.
