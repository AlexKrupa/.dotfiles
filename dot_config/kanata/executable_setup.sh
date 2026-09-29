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
if [ ! -f "$SUDOERS_FILE" ] || ! sudo grep -qF "$SUDOERS_LINE" "$SUDOERS_FILE"; then
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 0440 "$SUDOERS_FILE"
    echo "Created $SUDOERS_FILE"
else
    echo "$SUDOERS_FILE already configured"
fi

# 5. kanata and the driver speak a versioned protocol. A mismatched pair starts
#    with no error and gives no key output. kanata 1.13.0 and later needs driver
#    8.0.0 (protocol 7), older kanata needs 6.2.0. Homebrew stable is kanata
#    1.12.0, so this pins the 6.2.0 side.
KANATA_SERIES_EXPECTED="1.12"
KARABINER_DRIVER_EXPECTED="6.2.0"
KARABINER_DRIVER_URL="https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/tag/v$KARABINER_DRIVER_EXPECTED"
KARABINER_DAEMON_APP="/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app"

KANATA_VERSION="$("$KANATA_BIN" --version | awk '{print $2}')"
KANATA_SERIES="$(echo "$KANATA_VERSION" | cut -d. -f1,2)"
if [ "$KANATA_SERIES" != "$KANATA_SERIES_EXPECTED" ]; then
    echo "error: kanata $KANATA_VERSION installed, this setup pins $KANATA_SERIES_EXPECTED.x." >&2
    echo "       Check the driver requirement in kanata's docs/setup-macos.md, then update" >&2
    echo "       KANATA_SERIES_EXPECTED and KARABINER_DRIVER_EXPECTED in this script together." >&2
    exit 1
fi

if [ ! -d "$KARABINER_DAEMON_APP" ]; then
    echo "error: Karabiner DriverKit driver not installed. Install v$KARABINER_DRIVER_EXPECTED:" >&2
    echo "       $KARABINER_DRIVER_URL" >&2
    exit 1
fi
KARABINER_DRIVER_VERSION="$(defaults read "$KARABINER_DAEMON_APP/Contents/Info.plist" \
    CFBundleShortVersionString)"
if [ "$KARABINER_DRIVER_VERSION" != "$KARABINER_DRIVER_EXPECTED" ]; then
    echo "error: Karabiner driver $KARABINER_DRIVER_VERSION installed, kanata $KANATA_VERSION" >&2
    echo "       needs v$KARABINER_DRIVER_EXPECTED. Install it from:" >&2
    echo "       $KARABINER_DRIVER_URL" >&2
    exit 1
fi

# 6. Install the Karabiner virtual keyboard daemon as a LaunchDaemon. The driver
#    package ships no launchd job, and kanata has no key output without the
#    daemon. launchd rejects a /Library/LaunchDaemons plist that a non-root user
#    can write, so copy instead of symlink.
KARABINER_DAEMON_LABEL="org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon"
KARABINER_DAEMON_PLIST="/Library/LaunchDaemons/$KARABINER_DAEMON_LABEL.plist"
sudo install -o root -g wheel -m 0644 \
    "$SCRIPT_DIR/$KARABINER_DAEMON_LABEL.plist" "$KARABINER_DAEMON_PLIST"
sudo launchctl bootout "system/$KARABINER_DAEMON_LABEL" 2>/dev/null || true
sudo launchctl bootstrap system "$KARABINER_DAEMON_PLIST"

# 7. Stop the tray and every kanata process. A kanata that runs outside the
#    tray holds the keyboard, and the tray's own kanata then exits.
GUI_DOMAIN="gui/$(id -u)"
TRAY_LABEL="com.kanata-tray-macos"
TRAY_PLIST="$HOME/Library/LaunchAgents/$TRAY_LABEL.plist"
TRAY_LOG="$SCRIPT_DIR/kanata_tray_lastrun.log"
launchctl bootout "$GUI_DOMAIN/$TRAY_LABEL" 2>/dev/null || true
sudo pkill -x kanata || true

# 8. Start the tray and wait until it connects to kanata. kanata runs under
#    launchd, so macOS checks the permissions of kanata-tray-macos and kanata,
#    not of this terminal. Both binaries are ad hoc signed. macOS can drop
#    their grants while System Settings still shows them as enabled.
start_tray() {
    rm -f "$TRAY_LOG"
    launchctl bootstrap "$GUI_DOMAIN" "$TRAY_PLIST"
    for _ in $(seq 15); do
        grep -q "Connected to kanata" "$TRAY_LOG" 2>/dev/null && return 0
        sleep 1
    done
    launchctl bootout "$GUI_DOMAIN/$TRAY_LABEL" 2>/dev/null || true
    return 1
}

if ! start_tray; then
    cat <<EOF
kanata did not start. Grant permissions in System Settings > Privacy & Security.
Do these steps in Input Monitoring, then in Accessibility:
  1. Remove kanata and kanata-tray-macos with the - button, if they are in the list.
  2. Add these binaries with the + button. Press Cmd+Shift+G to type a path.
     $(realpath "$KANATA_BIN")
     $KANATA_TRAY_BIN
EOF
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    read -r -p "Press Enter when done. "
    if ! start_tray; then
        echo "error: kanata still does not start. See $TRAY_LOG" >&2
        echo "       To see the kanata error, run: $SCRIPT_DIR/kanata-sudo -c $SCRIPT_DIR/kanata.kbd" >&2
        exit 1
    fi
fi

echo "Done. kanata runs under kanata-tray."
