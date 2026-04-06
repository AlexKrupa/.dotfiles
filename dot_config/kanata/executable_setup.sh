#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KANATA_TRAY_VERSION="v0.8.0"

# 1. Download kanata-tray binary if missing
KANATA_TRAY_BIN="$SCRIPT_DIR/kanata-tray-macos"
if [ ! -x "$KANATA_TRAY_BIN" ]; then
    echo "Downloading kanata-tray $KANATA_TRAY_VERSION..."
    curl -L -o "$KANATA_TRAY_BIN" \
        "https://github.com/rszyma/kanata-tray/releases/download/$KANATA_TRAY_VERSION/kanata-tray-macos"
    chmod +x "$KANATA_TRAY_BIN"
fi

# 2. Symlink kanata-tray config to where kanata-tray expects it
KANATA_TRAY_CONFIG_DIR="$HOME/Library/Application Support/kanata-tray"
mkdir -p "$KANATA_TRAY_CONFIG_DIR"
ln -sf "$SCRIPT_DIR/kanata-tray.toml" "$KANATA_TRAY_CONFIG_DIR/kanata-tray.toml"

# 3. Symlink LaunchAgent plist.
#    Note: the plist hardcodes /Users/alexkrupa/... in ProgramArguments, so
#    this whole setup is single-user by design.
ln -sf "$SCRIPT_DIR/com.kanata-tray-macos.plist" "$HOME/Library/LaunchAgents/com.kanata-tray-macos.plist"

# 4. Set up passwordless sudo for kanata. Resolve the real binary via PATH so
#    this works on both Apple Silicon (/opt/homebrew) and Intel (/usr/local).
KANATA_BIN="$(command -v kanata || true)"
if [ -z "$KANATA_BIN" ]; then
    echo "error: kanata not found on PATH. Install it first (e.g. brew install kanata)." >&2
    exit 1
fi
SUDOERS_FILE="/etc/sudoers.d/kanata"
SUDOERS_LINE="$USER ALL=(root) NOPASSWD: $KANATA_BIN"
if [ ! -f "$SUDOERS_FILE" ] || ! grep -qF "$SUDOERS_LINE" "$SUDOERS_FILE"; then
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
    echo "Created $SUDOERS_FILE"
else
    echo "$SUDOERS_FILE already configured"
fi

# 5. Bootstrap the LaunchAgent into the GUI domain. This both starts it now
#    (RunAtLoad=true in the plist) and makes launchd auto-load it on every
#    future login. `|| true` so re-running setup.sh on an already-configured
#    machine doesn't abort under `set -e`.
#    If this step fails, just start kanata-tray manually this once:
#      open ~/.config/kanata/kanata-tray-macos
#    It will still come up automatically on next login.
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.kanata-tray-macos.plist" || true

cat <<'EOF'
Done. Remaining manual steps:

1. Grant macOS permissions in System Settings > Privacy & Security:
   - Input Monitoring: add kanata (and maybe kanata-tray macos if kanata alone doesn't work)
     /opt/homebrew/Cellar/kanata/<version>/bin/kanata  (real path, not the symlink)
   - Accessibility: same two binaries
   Use Cmd+Shift+G in the file picker to navigate to hidden paths.
EOF
