# kanata

kanata runs under [kanata-tray](https://github.com/rszyma/kanata-tray), which a LaunchAgent starts
at login. Karabiner-Elements is not necessary.

## Setup

Run `./setup.sh`. Run it again after a kanata upgrade or when kanata does not work.

The script stops all kanata processes, starts the tray, and waits until the tray connects to
kanata. If kanata does not start, the script opens System Settings and shows which binaries need
Input Monitoring and Accessibility permissions.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Tray shows `[ERR]`, keys work | A kanata process outside the tray holds the keyboard |
| Tray shows `[ERR]`, keys do not work | macOS denies Input Monitoring to kanata |

For both symptoms, run `./setup.sh`.

- To see the kanata error, run `./kanata-sudo -c kanata.kbd`.
- To see the tray log, open `kanata_tray_lastrun.log`.
