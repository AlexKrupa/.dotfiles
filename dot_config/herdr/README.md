# herdr config

## What is here

| Path                      | Purpose                                                              |
| ------------------------- | -------------------------------------------------------------------- |
| `config.toml`             | All settings and keybindings                                         |
| `bin/project`             | Focus or create a project workspace, for `alt+y/u/i/o/p`             |
| `bin/balance-panes.sh`    | `split`, `close`, `break`, `equalize` - one per keybinding           |
| `bin/balance.jq`          | Tree walks over a tab's layout, for `equalize` and `close`           |
| `bin/tests/test.sh`       | Fixtures for `bin/balance.jq`                                        |
| `plugins/balance-panes/`  | Local plugin: even out a tab when a pane's process ends on its own   |
| `plugins/worktree-links/` | Local plugin: symlink gitignored files into new worktrees            |
| `plugins/auto-label/`     | Local plugin: name each tab, number each tab, workspace and agent    |
| `plugins/caffeinate/`     | Local plugin: hold off sleep while an agent is working               |
| `plugins/config/`         | Config for installed plugins                                         |
| `projects.local`          | Machine-local project paths for `alt+y/u/i/o/p`, not in the dotfiles |
| `forks.conf`              | Forks of installed plugins, rebased by `herdr-forks-sync`            |
| `bin/pluck-open`          | Open handler for herdr-pluck's uppercase hints                       |
| `bin/pluck-post-close`    | Evens the group a pluck editor pane leaves when it closes itself     |

herdr owns `plugins/github/`, `plugins.json`, `session.json` and the `.log` and `.sock` files. Leave
those alone.

## Keys

Three direct layers, no prefix needed (the built-in actions also keep their prefix form):

- `alt` for tabs and panes,
- `alt+shift` for close tab, tab nav, swap pane and `alt+shift+1..9` to switch tab,
- `ctrl+alt` for agents and pane resize.

Workspaces have no direct layer: `alt+y/u/i/o/p` open the five projects, the rest stay on
`prefix+shift`.

The split and close keys are custom commands, not the built-in actions: they run
`bin/balance-panes.sh split` and `close`, which act over the CLI and then run its `equalize right`
or `down`. That evens only the group the pane joined or left - the unbroken run of same-direction
splits around it. Nesting elsewhere in the tab, and the other axis of the same nest, keep whatever
they were resized to. Closing the middle of three columns evens the two that are left. Closing a row
out of a column leaves that column's width alone. `alt+=` still evens the whole tab. A split or
close made by the CLI, a plugin or an agent is left alone, apart from the herdr-pluck opens below.
`plugins/balance-panes/` covers a pane whose process ends on its own.

`alt+g` opens lazygit in a new focused tab instead of a popup, so tab and pane keys keep working.
The tab holds one pane running `exec lazygit`, so quitting lazygit ends the pane and herdr closes
the tab. The pane starts through `HERDR_PANE_CMD`, which skips `conf.d`, so the command carries
`PATH`. `bin/lazygit.sh` first looks for a pane in the same workspace that runs lazygit in the same
directory, and focuses that tab instead. The match is cwd plus process name: a pane keeps no marker
of the key that opened it, and lazygit sets no terminal title.

`bin/balance.jq` holds the tree walks the subcommands share, and picks the splits and ratios.
`bin/tests/test.sh` covers it with fixture trees, no server needed.

## Custom plugins

### Project keys

`alt+y`, `alt+u`, `alt+i`, `alt+o` and `alt+p` read one absolute path per line from
`projects.local`. Line 1 is `alt+y`, line 2 `alt+u`, and so on through line 5 for `alt+p`. The key
focuses that workspace if it is open, and creates it if not. A missing file, blank line or comment
makes the key do nothing. That file is machine-local and stays out of the dotfiles.

### Balance on exit

`plugins/balance-panes/` hooks `pane.exited` and runs `bin/balance-panes.sh on-exit`. That covers a
pane whose process ended by itself - an agent that finished, a typed `exit`, a crash. No key fires
on those, so the close key never sees them.

Hooks get neither `HERDR_ACTIVE_PANE_ID` nor `HERDR_ACTIVE_TAB_ID`, and the `pane.exited` payload
has only `pane_id` and `workspace_id`. `HERDR_TAB_ID` is the one thing that names the tab, and it
names the exited pane's tab rather than the focused one. Measured on herdr 0.8.0.

The whole tab is evened, not one group: the pane is out of the tree by the time the hook runs, so no
group is left to name. `pane.closed` is not hooked - the close key already covers it, and that event
has no tab id.

### Worktree links

`herdr worktree create` fires the `worktree-links` plugin, which symlinks gitignored local files
from the main checkout into the new worktree. `links.conf` holds the global list. A repo can add its
own in `.herdr-links` at its root, and the two lists add up.

Paths are relative to the repo root. Absolute paths and anything containing `..` are skipped, as is
a file that does not exist or one the worktree already has. Git-tracked files arrive from
`git worktree add`, so in practice only gitignored files get linked.

### Auto label

`plugins/auto-label/` labels every tab `N • name`, where `N` is the tab's position in its
workspace and `name` describes the focused pane: the running command, the directory at an idle
prompt, or the agent name in an agent pane. `watch.sh` holds one `events.subscribe` connection to
the herdr socket and sweeps once per burst of events. `policy.jq` makes every decision and is
covered by `tests/test.sh`.

The name comes from the pane's foreground process, one `herdr pane process-info` per tab, not from
its terminal title. A title is not a name: lazygit, yazi and nvim leave the pane without one, and
`herdr api snapshot` carries no process information. The name is the leader of the foreground
process group, so a program that starts another keeps the tab on the one the shell started. A pane
whose leader is its shell counts as idle and takes the directory instead. An agent pane still takes
the agent name, and needs no process call.

A tab renamed by hand keeps its name and only gets its number maintained. Renaming it back to a bare
number, such as `2`, hands it back to automatic naming. Ownership lives in
`~/.local/state/herdr-auto-label/state.json`.

The sidebar is numbered too. Every workspace and agent gets an `idx` metadata token holding the slot
its `alt+1..9` or `ctrl+alt+1..9` binding uses, rendered by the `$idx` token in
`[ui.sidebar.spaces]` and `[ui.sidebar.agents]`. A workspace has a `number` of its own. An agent has
none, so its slot is its position in the snapshot's agents list. Nothing past the ninth slot is
numbered, because no binding reaches it. There is no bullet, unlike a tab label: herdr puts its own
separator between the tokens of a sidebar row.

A number is a display-only token, not a rename, so a workspace name typed by hand is never touched
and needs no ownership state. Only a token that differs from the one already set is written, which
also stops the write from feeding its own event back as more work.

The socket connection is a coprocess, so `watch.sh` itself holds the write end that keeps `nc`
alive. When the connection ends, the read loop sees EOF and reconnects.

`watch.sh` needs homebrew bash 5 for fractional `read -t` timeouts.

### Caffeinate

`plugins/caffeinate/` holds `caffeinate -i -w <watcher pid>` while any agent is `working`, so the
machine does not idle-sleep mid-turn. `-w` ties the assertion to the watcher, so a crash releases it
rather than leaving the machine unable to sleep. `decide` makes every call and is covered by
`tests/test.sh`.

`watch.sh` polls, unlike `plugins/auto-label/watch.sh`: herdr takes a `pane.agent_status_changed`
subscription only per `pane_id`, so no one request covers a session whose agent panes come and go.
Events would buy nothing here. A hold placed within `CAFFEINATE_INTERVAL` seconds, 30 by default, is
still minutes ahead of macOS idle sleep, and the release is a clock decision that no event
announces.

Only `working` counts. A `blocked` agent is parked waiting on an answer, so sleeping then loses
nothing. `CAFFEINATE_GRACE` seconds of quiet, 60 by default, releases the hold, which also covers
the pause between turns.

Lid-close sleep is a different code path and no assertion blocks it. Clamshell - lid closed on AC
with an external display - does not use that path, so it is covered. Lid closed on battery with no
external display is not, and cannot be without the kernel `SleepDisabled` flag and a sudoers grant
for `pmset -a disablesleep`. Every menu-bar app doing this uses that one mechanism, and none has a
CLI, so none can follow agent state. Treat them as a manual override if that case ever matters.

State lives in `~/.local/state/herdr-caffeinate/`.

### Forked plugins

`herdr-pluck` runs from [AlexKrupa/herdr-pluck](https://github.com/AlexKrupa/herdr-pluck). The fork
adds one thing: an uppercase hint runs `bin/pluck-open` on the match instead of copying it, so
`alt+c` covers both. `alt` cannot be used for this - herdr keybindings are global and take almost
every letter before a pane sees it. The plugin id stays `rmarganti.herdr-pluck`, so nothing else
moves.

`bin/pluck-open` splits the source pane for a text file (`$EDITOR`, pane closes on quit) or a
directory (`y`, pane stays in the directory yazi ended in), and falls back to `open` for everything
else. The split names `$HERDR_PLUCK_PANE_ID` explicitly because the picker's temporary tab is still
focused while the handler runs.

Both splits even out the column group they join, the same as the split keys. The editor pane closes
itself when the editor quits and no key fires on that, so its command ends with
`bin/pluck-post-close`: it re-runs itself detached, waits for the pane to go, then evens what is
left. A yazi pane is closed by key, so `bin/balance-panes.sh close` already covers it.

`herdr-upgrade` runs `herdr-forks-sync` first, which reads `forks.conf` and rebases each fork's
clone onto its upstream, then force-pushes. A conflict is reported and skipped, leaving the plugin
on its old commit until the rebase is finished by hand.

## Setup

```bash
brew install herdr jq fish fd neovim sesh television go bash yazi lazygit

herdr plugin install fullerzz/herdr-plugin-sesh
herdr plugin install thanhdat77/herdr-navigator
herdr plugin install AlexKrupa/herdr-pluck
herdr plugin install iurysza/termscope
herdr plugin install persiyanov/herdr-reviewr

chmod +x ~/.config/herdr/bin/* ~/.config/herdr/bin/tests/*.sh \
  ~/.config/herdr/plugins/*/*.sh ~/.config/herdr/plugins/*/tests/*.sh \
  ~/.config/herdr/plugins/*/tests/mocks/*
herdr plugin link ~/.config/herdr/plugins/balance-panes
herdr plugin link ~/.config/herdr/plugins/worktree-links
herdr plugin link ~/.config/herdr/plugins/auto-label
herdr plugin link ~/.config/herdr/plugins/caffeinate
herdr config check          # config: ok
herdr server reload-config  # status: applied, diagnostics: []
```

Dependencies:

- `jq` - `bin/project`, `bin/balance-panes.sh` and the split and close keys, worktree-links,
  `claude-upgrade`
- `bash` 5 - worktree-links, auto-label (macOS bash 3.2 has no fractional `read -t`)
- `go` 1.26.4+ - sesh plugin, built from source
- `fd`, `neovim`, `television` (`tv`), python 3.10+ - termscope, built from source
- `cargo` - herdr-navigator and the herdr-pluck fork, both built from source
- `yazi` - `bin/pluck-open`, for a plucked directory
- `lazygit` - `alt+g`

Plugins run with full user permissions.

Then create `projects.local` and press each plugin key. herdr does not validate plugin action ids,
so a keypress is the only proof they are right.

### Fish

Three files in `~/.config/fish/conf.d/`:

- `herdr.fish` runs `exec herdr` in interactive shells, with guards for herdr panes, editor
  terminals and IDE shells.
- `tmux_utils.fish` sets `fish_tmux_autostart false`.
- `claude.fish` makes `claude-upgrade` work under tmux or herdr.

`fish_tmux_autoquit` defaults to `fish_tmux_autostart`, so with autostart off, detaching herdr
leaves you at a shell instead of closing the window.

## Agent skill

Coding agents control herdr from inside a pane via the `herdr` skill: inspect workspaces, split
panes, run commands, read output, spawn helper agents. Installed globally with:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

Needs `HERDR_ENV=1`, which herdr sets in its panes. Docs: https://herdr.dev/docs/agent-skill/

## Known issue: yazi image preview

Yazi asks the terminal whether it supports Kitty graphics, and wraps that question for tmux and
zellij only. herdr is neither, so yazi sees no answer and falls back to chafa. `yazi --debug` in a
herdr pane shows which adapter it picked.

## Back to tmux

Set `fish_tmux_autostart` back to `true` in `tmux_utils.fish`, delete `herdr.fish`, open a new
terminal. Nothing in `~/.config/tmux/` was changed.
