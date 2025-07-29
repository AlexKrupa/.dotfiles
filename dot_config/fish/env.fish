# Default editor
set -gx EDITOR nvim
set -gx VISUAL nvim

# lazygit: change default config directory
set -gx XDG_CONFIG_HOME $HOME/.config

# JetBrains Toolbox
fish_add_path ~/Library/Application\ Support/JetBrains/Toolbox/scripts
fish_add_path ~/.jetbrains

# -----------------
# --- LANGUAGES ---
# -----------------

# --------------
# --- Python ---
# --------------

# Python
# /opt/homebrew/bin/python3

# Setting PATH for Python 3.9
# The original version is saved in ~/.config/fish/config.fish.pysave
# fish_add_path ~/Library/Frameworks/Python.framework/Versions/3.9/bin
fish_add_path -P ~/.local/py-tools-venv/bin
fish_add_path ~/.local/bin

# ------------
# --- Ruby ---
# ------------

# /usr/local/opt/ruby/bin
# $HOME/.gem/ruby/2.7.0/bin
# $HOME/gems/bin
rbenv init - | source
set -x GEM_HOME $HOME/.gem
set -x RUBY_CONFIGURE_OPTS "--with-openssl-dir='(brew --prefix openssl@1.1)'"

# ------------
# --- Rust ---
# ------------

fish_add_path ~/.cargo/bin

