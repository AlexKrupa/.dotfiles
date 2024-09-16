# Default editor
set -gx VISUAL nvim
set -gx EDITOR $VISUAL

# Android
set -gx JAVA_HOME (/usr/libexec/java_home)
set -gx ANDROID_HOME $HOME/Library/Android/sdk
set -gx ANDROID_SDK $ANDROID_HOME
set -gx ANDROID_SDK_ROOT $ANDROID_HOME

fish_add_path ~/Library/Android/sdk/cmdline-tools/latest/bin
fish_add_path ~/Library/Android/sdk/emulator
fish_add_path ~/Library/Android/sdk/platform-tools
fish_add_path ~/Library/Android/sdk/tools
fish_add_path ~/Library/Application\ Support/JetBrains/Toolbox/scripts
fish_add_path ~/.jetbrains

# ----------

# Brew
eval (/opt/homebrew/bin/brew shellenv)

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
