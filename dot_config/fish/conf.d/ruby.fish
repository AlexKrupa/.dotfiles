# Verbatim output of `rbenv init - fish` (32 ms), inlined. Only the shims path was edited,
# to $RBENV_ROOT. Re-run and re-paste after an rbenv upgrade.
set -gx PATH $RBENV_ROOT/shims $PATH
set -gx RBENV_SHELL fish
command rbenv rehash 2>/dev/null
function rbenv
  set command $argv[1]
  set -e argv[1]

  switch "$command"
  case rehash shell
    rbenv "sh-$command" $argv|source
  case '*'
    command rbenv "$command" $argv
  end
end

set -x GEM_HOME $HOME/.gem

# RUBY_CONFIGURE_OPTS is read by `rbenv install` alone, so `brew --prefix` (14 ms) is asked for
# only there. The copy keeps the function above, which handles `rbenv shell` and `rbenv rehash`.
functions --copy rbenv __rbenv_inner
function rbenv
    if test "$argv[1]" = install
        set -fx RUBY_CONFIGURE_OPTS "--with-openssl-dir="(brew --prefix openssl@3)
    end
    __rbenv_inner $argv
end

