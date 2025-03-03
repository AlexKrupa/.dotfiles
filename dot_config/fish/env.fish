# Default editor
set -gx VISUAL nvim
set -gx EDITOR $VISUAL

# lazygit: change default config directory
set -gx XDG_CONFIG_HOME $HOME/.config

fish_add_path /opt/homebrew/bin
fish_add_path ~/Library/Application\ Support/JetBrains/Toolbox/scripts
fish_add_path ~/.jetbrains

# ----------

# Python
# /opt/homebrew/bin/python3

# Setting PATH for Python 3.9
# The original version is saved in ~/.config/fish/config.fish.pysave
fish_add_path ~/Library/Frameworks/Python.framework/Versions/3.9/bin

if command -v pyenv 1>/dev/null 2>&1
  pyenv init - | source
end

# -----------

# Ruby
# /usr/local/opt/ruby/bin
# $HOME/.gem/ruby/2.7.0/bin
# $HOME/gems/bin
rbenv init - | source
set -x GEM_HOME $HOME/.gem

# Incompatible with Warp terminal: https://docs.warp.dev/help/known-issues#list-of-incompatible-tools
status --is-interactive; and source (rbenv init -|psub) # rbenv

set -x RUBY_CONFIGURE_OPTS "--with-openssl-dir='(brew --prefix openssl@1.1)'"

# Rust
fish_add_path ~/.cargo/bin
