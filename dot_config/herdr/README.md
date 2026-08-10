# herdr config

herdr replaced tmux here on 2026-08-09. `~/.config/tmux/` is still on disk and untouched, so going
back is two edits. See [Back to tmux](#back-to-tmux).

Prefix is `ctrl+space`, same as the old tmux prefix. Every default binding is written out in
`config.toml` so changing one is a one-line edit.

## What is here

| Path | Purpose |
| --- | --- |
| `config.toml` | All settings and keybindings |
| `bin/project` | Focus or create a project workspace, for `alt+y/u/i/o/p` |
| `bin/break-pane` | Move the focused pane to a new tab |
| `bin/equalize-panes` | Give every pane in the tab an equal share |
| `bin/herdr-rpc` | One JSON-RPC call to the herdr socket, for API calls the CLI does not expose |
| `plugins/worktree-links/` | Local plugin: symlink gitignored files into new worktrees |
| `plugins/config/` | Config for installed plugins |
| `projects.local` | Machine-local project paths for `alt+y/u/i/o/p`, not in the dotfiles |

herdr owns `plugins/github/`, `plugins.json`, `session.json` and the `.log` and `.sock` files.
Leave those alone.

## Keys

Three direct layers, no prefix needed: `alt` for tabs, `alt+shift` for workspaces, `ctrl+alt` for
agents. Every direct key also has a prefix form.

### Tabs and panes

| Key | Action | Prefix form |
| --- | --- | --- |
| `alt+t` | New tab, numbered, no name prompt | `prefix+c` |
| `alt+n` | Rename tab | `prefix+shift+t` |
| `alt+e` / `alt+r` | Previous / next tab | `prefix+p` / `prefix+n` |
| `alt+1..9` | Switch to tab N | `prefix+1..9` |
| `alt+W` | Close tab | `prefix+shift+x` |
| `alt+h/j/k/l` | Focus pane left/down/up/right | `prefix+h/j/k/l` |
| `alt+H/J/K/L` | Swap pane in that direction | `prefix+shift+h/j/k/l` |
| `alt+slash` | Split side by side | `prefix+v` |
| `alt+minus` | Split stacked | `prefix+minus` |
| `alt+w` | Close pane | `prefix+x` |
| `alt+z` | Zoom pane | `prefix+z` |
| `alt+v` | Copy mode | `prefix+[` |
| `alt+T` | Move pane to a new tab | - |
| `alt+=` | Even out splits | - |

### Workspaces and agents

| Key | Action | Prefix form |
| --- | --- | --- |
| `alt+shift+1..9` | Switch to workspace N | - |
| `alt+E` / `alt+R` | Previous / next workspace | - |
| `alt+G` | New git worktree | `prefix+shift+g` |
| `alt+y/u/i/o/p` | Project 1 to 5 from `projects.local` | - |
| `ctrl+alt+1..9` | Focus agent N in the sidebar | - |
| - | Workspace picker | `prefix+w` |
| - | Go to anything | `prefix+g` |

### Plugins

| Key | Action | Plugin |
| --- | --- | --- |
| `alt+s` | Session picker, reads `~/.config/sesh/sesh.toml` | `fullerzz.sesh` |
| `alt+d` | Previous workspace | `fullerzz.sesh` |
| `alt+a` | Jump to anything | `herdr-navigator` |
| `alt+c` | Copy with hints | `rmarganti.herdr-pluck` |
| `alt+C` | Open a link with hints | `rmarganti.herdr-pluck` |
| `alt+x` | Open a visible file | `termscope` |

### Other

`prefix+?` lists everything. `prefix+q` detaches, `prefix+b` toggles the sidebar, `prefix+r` enters
resize mode, `prefix+e` opens the scrollback in an editor, `prefix+shift+r` reloads this config.

## Project keys

`alt+y`, `alt+u`, `alt+i`, `alt+o` and `alt+p` read one absolute path per line from
`projects.local`. Line 1 is `alt+y`, line 2 `alt+u`, and so on through line 5 for `alt+p`. The key
focuses that workspace if it is open, and creates it if not. A missing file, blank line or comment
makes the key do nothing, so the keys stay quiet until the file is filled in. That file is machine-local and stays out of the dotfiles.

## Worktree links

`herdr worktree create` fires the `worktree-links` plugin, which symlinks gitignored local files
from the main checkout into the new worktree. `links.conf` holds the global list. A repo can add
its own in `.herdr-links` at its root, and the two lists add up.

Paths are relative to the repo root. Absolute paths and anything containing `..` are skipped, as is
a file that does not exist or one the worktree already has. Git-tracked files arrive from
`git worktree add`, so in practice only gitignored files get linked.

## New machine

```bash
brew install herdr jq fish fd neovim sesh yazi television go chafa

herdr plugin install fullerzz/herdr-plugin-sesh
herdr plugin install thanhdat77/herdr-navigator --ref v0.3.3
herdr plugin install rmarganti/herdr-pluck
herdr plugin install iurysza/termscope

chmod +x ~/.config/herdr/bin/* ~/.config/herdr/plugins/worktree-links/link.sh
herdr plugin link ~/.config/herdr/plugins/worktree-links
herdr config check          # config: ok
herdr server reload-config  # status: applied, diagnostics: []
```

`jq` is needed by `bin/project`, `bin/equalize-panes`, the worktree plugin and `claude-upgrade`.
`fd`, `neovim` and `television` are for termscope, whose binary is `tv`. `go` 1.26.4+ builds the
sesh plugin. `nc` and `bash` ship with macOS, and termscope also wants python 3.10+.

Plugins run with full user permissions. Two build from source, and termscope installs Television
through Homebrew.

Then create `projects.local`, and check the plugin keys work. herdr does not validate plugin action
ids, so a keypress is the only proof they are right.

### Fish

Three files in `~/.config/fish/conf.d/`:

- `herdr.fish` runs `exec herdr` in interactive shells, with guards for herdr panes, editor
  terminals and IDE shells.
- `tmux_utils.fish` sets `fish_tmux_autostart false`. That one word is its only herdr change.
- `claude.fish` makes `claude-upgrade` work under tmux or herdr.

`fish_tmux_autoquit` defaults to `fish_tmux_autostart`, so with autostart off, detaching herdr
leaves you at a shell instead of closing the window.

## Known issue: yazi image preview

Yazi asks the terminal whether it supports Kitty graphics, and wraps that question for tmux and
zellij only. herdr is neither, so yazi sees no answer and falls back to chafa. `yazi --debug` in a
herdr pane shows which adapter it picked.

## Back to tmux

Set `fish_tmux_autostart` back to `true` in `tmux_utils.fish`, delete `herdr.fish`, open a new
terminal. Nothing in `~/.config/tmux/` was changed.
