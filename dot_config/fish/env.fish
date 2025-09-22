# Default editor
set -gx EDITOR nvim
set -gx VISUAL nvim

# lazygit: change default config directory
set -gx XDG_CONFIG_HOME $HOME/.config

# Change default Goku config path from ~/.config/karabiner.edn
set -gx GOKU_EDN_CONFIG_FILE $HOME/.config/karabiner/karabiner.edn

# JetBrains Toolbox
fish_add_path ~/Library/Application\ Support/JetBrains/Toolbox/scripts
fish_add_path ~/.jetbrains

# ---------------
# --- Android ---
# ---------------
fish_add_path ~/src/me/adx

# ----------
# --- Go ---
# ----------
fish_add_path (go env GOPATH)/bin

# --------------
# --- Python ---
# --------------

# Before this, set up a virtual env with uv
# uv venv ~/.local/py-tools-venv/
fish_add_path -P ~/.local/py-tools-venv/bin
fish_add_path ~/.local/bin

# Alternatively, use `python@<version> -m pip install --break-system-packages --user <dependency>
# when installing a library that no Python application depends on but is expected by, e.g., a tmux plugin or a script.

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

