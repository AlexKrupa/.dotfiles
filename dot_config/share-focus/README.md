# share-focus

Crops a BetterDisplay virtual display stream to match the currently focused window. Instead of sharing the whole screen, only the active window region is visible.

Requires **Aerospace** (tiling WM) and **BetterDisplay** (virtual display).

After first compilation, the `sync` binary needs macOS accessibility permissions (System Settings > Privacy & Security > Accessibility).

## Components

- `sync.swift` - reads the focused window's bounds via Accessibility APIs, computes relative coordinates, and calls BetterDisplay CLI to update the partial screen crop. Compiled to `sync` binary by `service` on first run.
- `service` - manages sharing lifecycle: detects the main display, creates/connects a BetterDisplay virtual display named "Sharing", and toggles sharing on/off.

## Usage

```bash
# Toggle sharing on/off
./service

# Explicit start/stop/restart
./service start [--aspect W:H] [--downscale N]
./service stop
./service restart [--aspect W:H] [--downscale N]
./service status
```

`--aspect` sets the virtual display aspect ratio (default: `16:9`). `--downscale` divides the resolution by N (default: `1`).

```bash
./service start                      # 16:9 at full source-derived resolution
./service start --downscale 2        # 16:9 at half resolution (e.g. 1920x1080)
./service start --aspect 4:3         # 4:3 at full resolution
```

To recompile after editing `sync.swift`:

```bash
swiftc sync.swift -o sync
```

## Aerospace integration

Integrates through Aerospace configuration hooks in `aerospace.toml`:

- `on-focus-changed` calls `sync` on every focus change
- `exec-and-forget` calls `sync` for window-moving bindings

The tool calculates relative coordinates of the active window and updates BetterDisplay's partial screen sharing crop to match.
