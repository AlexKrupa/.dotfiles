# Environment variables — load before other conf.d files
set -gx XDG_CONFIG_HOME $HOME/.config
set -gx XDG_DATA_HOME $HOME/.local/share
set -gx XDG_STATE_HOME $HOME/.local/state
set -gx XDG_CACHE_HOME $HOME/.cache
set -gx EDITOR nvim
set -gx VISUAL nvim

# XDG relocations
set -gx GNUPGHOME $XDG_DATA_HOME/gnupg
set -gx CARGO_HOME $XDG_DATA_HOME/cargo
set -gx GOPATH $XDG_DATA_HOME/go
set -gx RBENV_ROOT $XDG_DATA_HOME/rbenv
set -gx PYENV_ROOT $XDG_DATA_HOME/pyenv
set -gx GRADLE_USER_HOME $XDG_DATA_HOME/gradle
set -gx NPM_CONFIG_CACHE $XDG_CACHE_HOME/npm
set -gx NPM_CONFIG_INIT_MODULE $XDG_CONFIG_HOME/npm/config/npm-init.js
set -gx LESSHISTFILE $XDG_STATE_HOME/lesshst
set -gx PYTHON_HISTORY $XDG_STATE_HOME/python_history
