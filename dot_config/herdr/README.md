# herdr config

## What is here

| Path                      | Purpose                                                            |
| ------------------------- | ------------------------------------------------------------------ |
| `config.toml`             | All settings and keybindings                                       |
| `bin/project`             | Focus or create a project workspace                                |
| `bin/balance-panes.sh`    | `split`, `close`, `break`, `equalize` - one per keybinding         |
| `bin/balance.jq`          | Tree walks over a tab's layout, for `equalize` and `close`         |
| `bin/tests/test.sh`       | Fixtures for `bin/balance.jq`                                      |
| `plugins/balance-panes/`  | Local plugin: even out a tab when a pane's process ends on its own |
| `plugins/worktree-links/` | Local plugin: symlink gitignored files into new worktrees          |
| `plugins/auto-label/`     | Local plugin: name each tab, number each tab, workspace and agent  |
| `plugins/caffeinate/`     | Local plugin: hold off sleep while an agent is working             |
| `plugins/config/`         | Config for installed plugins                                       |
| `projects.local`          | Machine-local project paths, not in the dotfiles                   |
| `forks.conf`              | Forks of installed plugins, rebased by `herdr-forks-sync`          |
| `bin/pluck-open`          | Open handler for herdr-pluck's uppercase hints                     |
| `bin/pluck-post-close`    | Evens the group a pluck editor pane leaves when it closes itself   |
| `setup.sh`                | Installs and links every plugin, on a new machine or a stale one   |

herdr owns `plugins/github/`, `plugins.json`, `session.json` and the `.log` and `.sock` files. Leave
those alone.

## Balance panes

The split and close keys run `bin/balance-panes.sh` instead of the built-in actions. Each acts over
the CLI, then evens only the group the pane joined or left - the unbroken run of same-direction
splits around it. Everything else keeps its resized size. `bin/balance.jq` holds the tree walks and
is covered by `bin/tests/test.sh`, no server needed.

A split or close made by the CLI, a plugin or an agent is left alone. `plugins/balance-panes/` hooks
`pane.exited` for a pane whose process ended by itself, where no key fires.

Hooks get neither `HERDR_ACTIVE_PANE_ID` nor `HERDR_ACTIVE_TAB_ID`, and the `pane.exited` payload
has only `pane_id` and `workspace_id`. `HERDR_TAB_ID` is the only tab identifier, and it holds the
exited pane's tab, not the focused one. Measured on herdr 0.8.0. The whole tab is evened, because
the pane is out of the tree by the time the hook runs. `pane.closed` is not hooked - the close key
covers it, and that event has no tab id.

## Worktree links

`herdr worktree create` fires the `worktree-links` plugin, which symlinks gitignored local files
from the main checkout into the new worktree. `links.conf` holds the global list. A repo can add its
own in `.herdr-links` at its root. Paths are relative to the repo root. Absolute paths, `..`,
missing files and files the worktree already has are skipped.

## Auto label

`plugins/auto-label/` names and numbers every tab, and numbers the sidebar. `watch.sh` holds one
`events.subscribe` connection and sweeps once per burst. `policy.jq` makes every decision and is
covered by `tests/test.sh`.

The name comes from `herdr pane process-info`, not the terminal title: lazygit, yazi and nvim set no
title, and `herdr api snapshot` has no process information. The name is the leader of the foreground
process group, so a program that starts another keeps the first name. A pane whose leader is its
shell counts as idle and takes its directory.

A tab renamed by hand keeps its name and only gets its number maintained. Renaming it to a bare
number hands it back. Ownership lives in `~/.local/state/herdr-auto-label/state.json`. A sidebar
number is a display-only metadata token, not a rename, so it needs no ownership state. Only a
changed token is written, which stops the write from feeding its own event back.

The socket connection is a coprocess, so `watch.sh` holds the write end that keeps `nc` alive. On
EOF the read loop reconnects. `watch.sh` needs homebrew bash 5 for fractional `read -t` timeouts.

## Caffeinate

`plugins/caffeinate/` holds `caffeinate -i -w <watcher pid>` while any agent is `working`. `-w` ties
the assertion to the watcher, so a crash releases it. State lives in
`~/.local/state/herdr-caffeinate/`. `decide` makes every call and is covered by `tests/test.sh`.

`watch.sh` polls, unlike `plugins/auto-label/watch.sh`: herdr takes a `pane.agent_status_changed`
subscription only per `pane_id`, so no one request covers a session whose agent panes come and go.
The poll interval is still minutes ahead of idle sleep.

Lid-close sleep is a different code path that no assertion blocks. Clamshell on AC with an external
display is covered. Lid closed on battery with no external display needs the kernel `SleepDisabled`
flag and a sudoers grant for `pmset -a disablesleep`.

## Forked plugins

`herdr-pluck` runs from AlexKrupa/herdr-pluck (https://github.com/AlexKrupa/herdr-pluck). The fork
adds one thing: an uppercase hint runs `bin/pluck-open` on the match instead of copying it. The
plugin id stays `rmarganti.herdr-pluck`. It is linked from the clone at `~/src/me/herdr-pluck`, not
installed from GitHub, so `herdr-forks-sync` has a working tree to rebase.

`bin/pluck-open` splits the source pane for a text file (`$EDITOR`) or a directory (`y`), and falls
back to `open`. It names `$HERDR_PLUCK_PANE_ID` explicitly, because the picker's temporary tab is
still focused. The editor pane closes itself with no key event, so its command ends with
`bin/pluck-post-close`, which re-runs itself detached and evens what is left.

`herdr-upgrade` runs `herdr-forks-sync` first, which rebases each fork in `forks.conf` onto its
upstream and force-pushes. A conflict is reported and skipped.

## Setup

```bash
brew install herdr jq fish fd neovim sesh television go bash yazi lazygit
git clone https://github.com/AlexKrupa/herdr-pluck.git ~/src/me/herdr-pluck
~/.config/herdr/setup.sh
```

`setup.sh` installs the GitHub plugins, links the local ones, sets the exec bits, then checks and
reloads the config. Only plugins - brew and the fork clone are not covered. It is safe to re-run: a
plugin that is already there is skipped, so it also syncs a machine that is missing one.
`herdr-upgrade` runs it first for that reason.

Dependencies:

- `jq` - `bin/project`, `bin/balance-panes.sh`, worktree-links, `claude-upgrade`
- `bash` 5 - worktree-links, auto-label (macOS bash 3.2 has no fractional `read -t`)
- `go` 1.26.4+ - sesh plugin, built from source
- `fd`, `neovim`, `television` (`tv`), python 3.10+ - termscope, built from source
- `cargo` - herdr-navigator and the herdr-pluck fork, both built from source
- `yazi` - `bin/pluck-open`, for a plucked directory
- `lazygit` - opened in its own tab

Plugins run with full user permissions.

Then create `projects.local`, one absolute path per line, and press each plugin key. herdr does not
validate plugin action ids. A keypress is the only proof they are right.

### Fish

Three files in `~/.config/fish/conf.d/`:

- `herdr.fish` runs `exec herdr` in interactive shells, with guards for herdr panes, editor
  terminals and IDE shells.
- `tmux_utils.fish` sets `fish_tmux_autostart false`.
- `claude.fish` makes `claude-upgrade` work under tmux or herdr.

`fish_tmux_autoquit` defaults to `fish_tmux_autostart`. With autostart off, detaching herdr leaves
you at a shell instead of closing the window.

## Agent skill

Coding agents control herdr from inside a pane via the `herdr` skill. Installed globally with:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

Needs `HERDR_ENV=1`, which herdr sets in its panes. Docs: https://herdr.dev/docs/agent-skill/

## Known issue: yazi image preview

Yazi asks the terminal whether it supports Kitty graphics, and wraps that question for tmux and
zellij only. herdr is neither, so yazi falls back to chafa. `yazi --debug` in a herdr pane shows the
adapter it picked.

## Back to tmux

Set `fish_tmux_autostart` back to `true` in `tmux_utils.fish`, delete `herdr.fish`, open a new
terminal. Nothing in `~/.config/tmux/` was changed.
