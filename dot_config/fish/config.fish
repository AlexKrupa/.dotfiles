# Skip interactive setup when loaded by IDE
if set -q INTELLIJ_ENVIRONMENT_READER
  exit 0
end

source ~/.config/fish/colors.fish
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

if test -f ~/.config/fish/local.fish
  source ~/.config/fish/local.fish
end

function fish --wraps fish --description "Replace shell inside tmux, subshell otherwise"
    if test (count $argv) -eq 0; and set -q TMUX
        exec command fish
    end
    command fish $argv
end

alias fishc "$EDITOR ~/.config/fish/config.fish"
alias fishl "$EDITOR ~/.config/fish/local.fish"
alias aerospacec "$EDITOR ~/.config/aerospace/aerospace.toml"
alias ghosttyc "$EDITOR ~/.config/ghostty/config"
alias ideavimc "$EDITOR ~/.ideavimrc"
alias nvimc "$EDITOR ~/.config/nvim/init.lua"
alias skhdc "$EDITOR ~/.config/skhd/skhdrc"
alias vimc "$EDITOR ~/.vimrc"

alias cd "z" # zoxide
alias ls "lsd -a --long"
alias dl "cd ~/Downloads"
alias dlf "open ~/Downloads"
alias finder "open ."
alias share "~/.config/share-focus/service"

