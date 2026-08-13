# herdr config

## What is here

| Path                      | Purpose                                                                      |
| ------------------------- | ---------------------------------------------------------------------------- |
| `config.toml`             | All settings and keybindings                                                 |
| `bin/project`             | Focus or create a project workspace, for `alt+y/u/i/o/p`                     |
| `bin/break-pane`          | Move the focused pane to a new tab                                           |
| `bin/split-pane`          | Split the active pane, then even out the group the new pane joins            |
| `bin/close-pane`          | Close the active pane, then even out the group it leaves behind              |
| `bin/equalize-panes`      | Even out the whole tab, or one row or column group with `right` or `down`    |
| `bin/layout.jq`           | Tree walks over a tab's layout, shared by the three above                    |
| `bin/tests/test.sh`       | Fixtures for `bin/layout.jq`                                                 |
| `bin/herdr-rpc`           | One JSON-RPC call to the herdr socket, for API calls the CLI does not expose |
| `plugins/worktree-links/` | Local plugin: symlink gitignored files into new worktrees                    |
| `plugins/tab-name/`       | Local plugin: name each tab after its focused pane                           |
| `plugins/config/`         | Config for installed plugins                                                 |
| `projects.local`          | Machine-local project paths for `alt+y/u/i/o/p`, not in the dotfiles         |
| `forks.conf`              | Forks of installed plugins, rebased by `herdr-forks-sync`                    |
| `bin/pluck-open`          | Open handler for herdr-pluck's uppercase hints                               |
| `bin/pluck-post-close`    | Evens the group a pluck editor pane leaves when it closes itself             |

herdr owns `plugins/github/`, `plugins.json`, `session.json` and the `.log` and `.sock` files. Leave
those alone.

## Keys

Three direct layers, no prefix needed (but every direct key also has a prefix form):

- `alt` for tabs,
- `alt+shift` for workspaces,
- `ctrl+alt` for agents.

The split and close keys are custom commands, not the built-in actions: they run `bin/split-pane`
and `bin/close-pane`, which act over the CLI and then run `bin/equalize-panes right` or `down`. That
evens only the group the pane joined or left - the unbroken run of same-direction splits around it.
Nesting elsewhere in the tab, and the other axis of the same nest, keep whatever they were resized
to. Closing the middle of three columns evens the two that are left; closing a row out of a column
leaves that column's width alone. `alt+=` still evens the whole tab. A split or close made by the
CLI, a plugin or an agent is left alone, apart from the herdr-pluck opens below.

`bin/layout.jq` holds the tree walks all three scripts share, and picks the splits and ratios.
`bin/tests/test.sh` covers it with fixture trees, no server needed.

## Custom plugins

### Project keys

`alt+y`, `alt+u`, `alt+i`, `alt+o` and `alt+p` read one absolute path per line from
`projects.local`. Line 1 is `alt+y`, line 2 `alt+u`, and so on through line 5 for `alt+p`. The key
focuses that workspace if it is open, and creates it if not. A missing file, blank line or comment
makes the key do nothing, so the keys stay quiet until the file is filled in. That file is
machine-local and stays out of the dotfiles.

### Worktree links

`herdr worktree create` fires the `worktree-links` plugin, which symlinks gitignored local files
from the main checkout into the new worktree. `links.conf` holds the global list. A repo can add its
own in `.herdr-links` at its root, and the two lists add up.

Paths are relative to the repo root. Absolute paths and anything containing `..` are skipped, as is
a file that does not exist or one the worktree already has. Git-tracked files arrive from
`git worktree add`, so in practice only gitignored files get linked.

### Tab names

`plugins/tab-name/` labels every tab `N • name`, where `N` is the tab's position in its workspace
and `name` describes the focused pane: the running command, the directory at an idle prompt, or the
agent name in an agent pane. `watch.sh` holds one `events.subscribe` connection to the herdr socket
and sweeps once per burst of events; `policy.jq` makes every decision and is covered by
`tests/test.sh`.

A tab renamed by hand keeps its name and only gets its number maintained. Renaming it back to a bare
number, such as `2`, hands it back to automatic naming. Ownership lives in
`~/.local/state/herdr-tab-name/state.json`.

`watch.sh` needs homebrew bash 5 for fractional `read -t` timeouts.

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
left. A yazi pane is closed by key, so `bin/close-pane` already covers it.

`herdr-upgrade` runs `herdr-forks-sync` first, which reads `forks.conf` and rebases each fork's
clone onto its upstream, then force-pushes. A conflict is reported and skipped, leaving the plugin
on its old commit until the rebase is finished by hand.

## Setup

```bash
brew install herdr jq fish fd neovim sesh television go bash

herdr plugin install fullerzz/herdr-plugin-sesh
herdr plugin install thanhdat77/herdr-navigator
herdr plugin install AlexKrupa/herdr-pluck
herdr plugin install iurysza/termscope

chmod +x ~/.config/herdr/bin/* ~/.config/herdr/bin/tests/*.sh \
  ~/.config/herdr/plugins/*/*.sh ~/.config/herdr/plugins/*/tests/*.sh
herdr plugin link ~/.config/herdr/plugins/worktree-links
herdr plugin link ~/.config/herdr/plugins/tab-name
herdr config check          # config: ok
herdr server reload-config  # status: applied, diagnostics: []
```

Dependencies:

- `jq` - `bin/project`, `bin/equalize-panes` and the split and close keys, worktree-links,
  `claude-upgrade`
- `bash` 5 - worktree-links, tab-name (macOS bash 3.2 has no fractional `read -t`)
- `go` 1.26.4+ - sesh plugin, built from source
- `fd`, `neovim`, `television` (`tv`), python 3.10+ - termscope, built from source
- `cargo` - herdr-navigator and the herdr-pluck fork, both built from source

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
