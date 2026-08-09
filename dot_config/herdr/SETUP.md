# herdr setup on a new machine

Built against herdr 0.8.0 on macOS, fish 4.8.1.

## 1. Install

```bash
brew install herdr jq fish fd neovim sesh yazi television go chafa
```

| Package | Used by |
| --- | --- |
| `herdr` | the multiplexer |
| `jq` | `bin/project`, `bin/equalize-panes`, the `worktree-links` plugin, `claude-upgrade` |
| `fish` | `config.toml` sets it as `default_shell` |
| `fd`, `neovim`, `television` | the `termscope` plugin (Television's binary is `tv`) |
| `go` | `fullerzz.sesh` builds from source, needs 1.26.4+ |
| `sesh` | `fullerzz.sesh` reads `~/.config/sesh/sesh.toml` |
| `yazi`, `chafa` | file manager, and its fallback for image preview |

`nc` and `bash` ship with macOS. `termscope` also needs python 3.10+.

## 2. Plugins

```bash
herdr plugin install fullerzz/herdr-plugin-sesh
herdr plugin install thanhdat77/herdr-navigator --ref v0.3.3
herdr plugin install rmarganti/herdr-pluck
herdr plugin install hotchpotch/herdr-tiny-fingers
herdr plugin install iurysza/termscope
```

Plugins run with full user permissions. `herdr-plugin-sesh` and `herdr-tiny-fingers` build from
source. `termscope` installs Television through Homebrew as a build step.

## 3. Config

These come from the dotfiles repo into `~/.config/herdr/`:

```
config.toml
bin/herdr-rpc
bin/break-pane
bin/project
bin/equalize-panes
plugins/worktree-links/herdr-plugin.toml
plugins/worktree-links/link.sh
plugins/worktree-links/links.conf
plugins/config/rmarganti.herdr-pluck/config.toml
plugins/config/hotchpotch.herdr-tiny-fingers/config.toml
```

Then:

```bash
chmod +x ~/.config/herdr/bin/* ~/.config/herdr/plugins/worktree-links/link.sh
herdr plugin link ~/.config/herdr/plugins/worktree-links
herdr config check          # config: ok
herdr server reload-config  # status: applied, diagnostics: []
```

`~/.config/herdr/plugins/` is herdr's own directory. Put the local plugin at
`plugins/worktree-links/` and leave `plugins/github/` alone.

## 4. Project keys

`alt+u`, `alt+i` and `alt+o` read `~/.config/herdr/projects.local`, one absolute path per line.
Create it with your three project paths. Without it the keys do nothing.

## 5. Fish

Three files in `~/.config/fish/conf.d/`:

- `herdr.fish` runs `exec herdr` in interactive shells, guarded so it skips herdr panes, editor
  terminals and IDE shells.
- `tmux_utils.fish` sets `fish_tmux_autostart false`. That one word is its only herdr change.
- `claude.fish` makes `claude-upgrade` work under tmux or herdr.

Setting `fish_tmux_autostart false` also turns off `fish_tmux_autoquit`, so detaching herdr leaves
you at a shell instead of closing the window.

## 6. Check it works

```bash
herdr plugin list         # 6 plugins, enabled
herdr plugin action list  # 10 actions
```

In a herdr pane, `prefix+?` (prefix is `ctrl+space`) lists every binding. Press each plugin key:
`alt+s` `alt+a` `alt+d` `alt+q` `alt+c` `alt+C` `alt+x`. herdr does not validate plugin action ids,
so a keypress is the only way to know they are right.

## Known issue: yazi image preview

Yazi asks the terminal whether it supports Kitty graphics, and wraps that question for tmux and
zellij only. herdr is neither, so yazi sees no answer and falls back to chafa. Run `yazi --debug` in
a herdr pane to see which adapter it picked.

## Rollback to tmux

`~/.config/tmux/` is untouched. Set `fish_tmux_autostart` back to `true` in `tmux_utils.fish`,
delete `herdr.fish`, open a new terminal.
