# share-focus

Crops a BetterDisplay virtual display stream to match the focused window. Share a single window instead of your whole screen.

Requires **Aerospace** (tiling WM) and **BetterDisplay** (virtual display). First run needs macOS accessibility permissions (System Settings > Privacy & Security > Accessibility).

## Architecture

Two components, no build system:

- `share-focus.swift` - Swift binary. Default mode: reads focused window bounds via Accessibility APIs, converts to relative coordinates, calls BetterDisplay CLI to update the crop. With `--watch`: daemon that syncs on window drag completion (CGEventTap on mouse events, 50ms debounce). Compiled to `share-focus` by `service` on first run. PID stored in `.cache/watcher.pid`.
- `service` - Bash script managing the sharing lifecycle: finds the main display, creates a BetterDisplay virtual display "Sharing", writes config to `.cache/sharing-enabled`, starts the watcher.

Data flow: `service start` writes `DisplayName|width height` to `.cache/sharing-enabled`. `share-focus` reads it, gets window bounds via `kAXFocusedWindowAttribute`, converts to 0.0-1.0 coordinates, and calls `BetterDisplay set -stream -partialOriginX/Y/Width/Height`. Sync triggers: Aerospace hooks (focus changes, keyboard moves) and the watch daemon (mouse drags).

## Usage

```bash
# Toggle sharing on/off
./service

# Explicit start/stop/restart
./service start [--aspect W:H] [--downscale N] [--delay MS] [--preview]
./service stop
./service restart [--aspect W:H] [--downscale N] [--delay MS] [--preview]
./service status

# Toggle preview window while sharing
./service preview

# Examples
./service start                      # 16:9 at half resolution (e.g. 1920x1080)
./service start --preview            # same, with floating preview window
./service start --downscale 1        # 16:9 at full 4K resolution
./service start --aspect 4:3         # 4:3 at half resolution
./service start --delay 25           # 25ms delay before reading window bounds

# Manual sync (no-op when sharing is off)
./share-focus

# Recompile after editing Swift source
swiftc share-focus.swift -o share-focus
```

- `--aspect` - virtual display aspect ratio (default: `16:9`)
- `--downscale` - divide resolution by N (default: `2`)
- `--delay` - ms to wait before reading window bounds, for Aerospace transitions (default: `0`)
- `--preview` - open a floating preview window

## Aerospace integration

Hooks in `aerospace.toml`:

- `on-focus-changed` calls `share-focus` on every focus change
- `exec-and-forget` calls `share-focus` for window-moving bindings

## Key details

- `share-focus` exits silently (exit 0) when sharing is off or bounds can't be read - it runs on every focus change, so this is expected.
- BetterDisplay CLI path is hardcoded to `/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay`.
- Only `AXStandardWindow` subrole windows are tracked (not dialogs, banners, etc.).
- Window coordinates are clamped to display bounds before conversion.
- The watch daemon fires on any mouseUp after a drag (including text selection). Harmless - sync is idempotent.

## Known limitations

- Display resolution is cached at `service start` in `.cache/sharing-enabled`. If resolution changes while sharing (display reconnect, clamshell, etc.), crop coordinates break. Fix: `./service restart`.
