rbenv init - | source
set -x GEM_HOME $HOME/.gem
set -x RUBY_CONFIGURE_OPTS "--with-openssl-dir='(brew --prefix openssl@1.1)'"

