source ~/.config/fish/env.fish
source ~/.config/fish/alias.fish
source ~/.config/fish/colors.fish

if test -f ~/.config/fish/local.fish
  source ~/.config/fish/local.fish
end

java17 # default Java version
starship init fish | source
fish_vi_key_bindings # Vim mode, fish_default_key_bindings for default
fzf_configure_bindings
# fzf --fish | source
