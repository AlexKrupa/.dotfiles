source ~/.config/fish/env.fish
source ~/.config/fish/alias.fish
source ~/.config/fish/colors.fish

jdk 21 --silent # default Java version
starship init fish | source
fish_vi_key_bindings # Vim mode, fish_default_key_bindings for default
fish_vi_cursor
fx --comp fish | source
zoxide init fish | source
eval "$(gs shell completion fish)" # git-spice completions

set fish_greeting # Disable the greeting
set -g fish_cursor_default block
set -g fish_cursor_insert line
set -g fish_cursor_replace underscore
set -g fish_cursor_replace_one underscore
set -g fish_cursor_visual block
set -g fish_vi_force_cursor 1

# fzf
fzf_configure_bindings
set -Ux FZF_DEFAULT_COMMAND "fd --type f --strip-cwd-prefix --hidden --follow --exclude .git"
# style: default, full, minimal
set -Ux FZF_DEFAULT_OPTS (printf '%s ' \
    '--style=minimal' \
    '--border' \
    # '--layout=reverse' \
    '--info=hidden' \
    | string collect)

if test -f ~/.config/fish/local.fish
  source ~/.config/fish/local.fish
end

status is-interactive; and begin
    set fish_tmux_autostart true
end
