source $XDG_CONFIG_HOME/fish/colors.fish

# Default editor
set -gx EDITOR nvim
set -gx VISUAL nvim

# lazygit: change default config directory
set -gx XDG_CONFIG_HOME $HOME/.config

starship init fish | source
fish_vi_key_bindings # Vim mode, fish_default_key_bindings for default
fish_vi_cursor
fx --comp fish | source
zoxide init fish | source

set fish_greeting # Disable the greeting
set -g fish_cursor_default block
set -g fish_cursor_insert line
set -g fish_cursor_replace underscore
set -g fish_cursor_replace_one underscore
set -g fish_cursor_visual block
set -g fish_vi_force_cursor 1

# Automatic command colorizer
# https://github.com/garabik/grc
if test -f /opt/homebrew/etc/grc.fish
  source /opt/homebrew/etc/grc.fish
end

if test -f $XDG_CONFIG_HOME/fish/local.fish
  source $XDG_CONFIG_HOME/fish/local.fish
end

alias fishc "$EDITOR $XDG_CONFIG_HOME/fish/config.fish"
alias fishr "source $XDG_CONFIG_HOME/fish/**/*.fish"
alias fishl "$EDITOR $XDG_CONFIG_HOME/fish/local.fish"
alias aerospacec "$EDITOR $XDG_CONFIG_HOME/aerospace/aerospace.toml"
alias ghosttyc "$EDITOR $XDG_CONFIG_HOME/ghostty/config"
alias ideavimc "$EDITOR ~/.ideavimrc"
alias nvimc "$EDITOR $XDG_CONFIG_HOME/nvim/init.lua"
alias skhdc "$EDITOR $XDG_CONFIG_HOME/skhd/skhdrc"
alias vimc "$EDITOR ~/.vimrc"

alias cd "z" # zoxide
alias ls "lsd -a --long"
alias dl "cd ~/Downloads"
alias dlf "open ~/Downloads"
alias finder "open ."
alias share "$XDG_CONFIG_HOME/share-focus/service"

