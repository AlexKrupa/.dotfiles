# herdr config

## What is here

| Path                             | Purpose                                                   |
| -------------------------------- | --------------------------------------------------------- |
| `config.toml`                    | All settings and keybindings                              |
| `bin/`                           | Scripts run by keybindings and plugins                    |
| `plugins/balance-panes/`         | Even out a tab when a pane's process ends on its own      |
| `plugins/worktree-links/`        | Symlink gitignored files into new worktrees               |
| `plugins/labels/`                | Name tabs, number rows, group agents by repo              |
| `plugins/caffeinate/`            | Hold off sleep while an agent is working                  |
| `plugins/nvim-sidebar-size-fix/` | Resize an nvim sidebar that keeps its start size          |
| `plugins/config/`                | Config for installed plugins                              |
| `projects.local`                 | Machine-local project paths, not in the dotfiles          |
| `forks.conf`                     | Forks of installed plugins, rebased by `herdr-forks-sync` |
| `setup.sh`                       | Installs and links every plugin                           |

herdr owns `plugins/github/`, `plugins.json`, `session.json` and the `.log` and `.sock` files. Leave
those alone.

The split and close keys run `bin/balance-panes.sh` instead of the built-in actions. It evens only
the group the pane joined or left. `bin/balance.jq` holds the tree walks, covered by
`bin/tests/test.sh`.

`herdr-pluck` runs from a fork (https://github.com/AlexKrupa/herdr-pluck). If a clone exists at
`~/src/me/herdr-pluck`, `setup.sh` links it. If not, `setup.sh` installs the fork from GitHub.
`herdr-forks-sync` rebases only the clone. Uppercase hints open the match with `bin/pluck-open`
instead of copying it.

## Setup

```bash
brew install herdr jq fish fd neovim sesh television go bash yazi lazygit
~/.config/herdr/setup.sh
```

`setup.sh` covers plugins only, not brew and not the fork clone. It is safe to re-run, so it also
syncs a machine that is missing a plugin. It also finds plugins that are not in its lists and
removes them after you confirm. `herdr-upgrade` runs it first.

Then create `projects.local`, one absolute path per line, and press each plugin key. herdr does not
validate plugin action ids, so a keypress is the only proof they are right.

Fish needs three files in `~/.config/fish/conf.d/`: `herdr.fish` (runs `exec herdr` in interactive
shells), `tmux_utils.fish` (`fish_tmux_autostart false`), and `claude.fish`.

## Agent skill

Coding agents control herdr from inside a pane via the `herdr` skill:

```bash
npx skills add herdrdev/herdr --skill herdr -g
```

Docs: https://herdr.dev/docs/agent-skill/

## Known issue: yazi image preview

Yazi wraps its Kitty graphics query for tmux and zellij only. herdr is neither, so yazi falls back
to chafa.

## Back to tmux

Set `fish_tmux_autostart` back to `true`, delete `herdr.fish`, open a new terminal. Nothing in
`~/.config/tmux/` was changed.
