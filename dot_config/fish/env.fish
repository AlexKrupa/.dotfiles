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

# Before this, set up a virtual env with uv
# uv venv ~/.local/py-tools-venv/
fish_add_path -P ~/.local/py-tools-venv/bin
fish_add_path ~/.local/bin

# ------------
# --- Ruby ---
# ------------

rbenv init - | source
set -x GEM_HOME $HOME/.gem
set -x RUBY_CONFIGURE_OPTS "--with-openssl-dir='(brew --prefix openssl@1.1)'"

# ------------
# --- Rust ---
# ------------

fish_add_path ~/.cargo/bin

