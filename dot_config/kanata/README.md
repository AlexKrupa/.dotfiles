# kanata

kanata runs under [kanata-tray](https://github.com/rszyma/kanata-tray), which a LaunchAgent starts
at login. Karabiner-Elements is not necessary.

## Setup

Run `./setup.sh`. After a kanata upgrade, or when kanata does not work, run it again.

kanata runs as root. The script copies the Homebrew binary to `/usr/local/kanata/kanata`, which
only root can change. The sudoers rule allows only that copy with the arguments of the presets in
`kanata-tray.toml`. If you change a preset path or port, change the rule in `setup.sh` too. A
`brew upgrade kanata` has no effect until you run `./setup.sh` again.

The script stops all kanata processes, starts the tray, and waits until the tray connects to
kanata. If kanata does not start, the script opens System Settings and shows which binaries need
Input Monitoring and Accessibility permissions.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Tray shows `[ERR]`, keys work | A kanata process outside the tray holds the keyboard |
| Tray shows `[ERR]`, keys do not work | macOS denies Input Monitoring to kanata |

For both symptoms, run `./setup.sh`.

- To see the kanata error, run `./kanata-sudo -c "$PWD/kanata.kbd" --port 5829`. If the
  arguments do not match the rule exactly, sudo asks for a password.
- To see the tray log, open `kanata_tray_lastrun.log`.
