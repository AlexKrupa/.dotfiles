# Yazi shell wrapper that provides the ability to change the current working directory when exiting Yazi.
# https://yazi-rs.github.io/docs/quick-start#shell-wrapper
function y
  set -l tmp (mktemp -t "yazi-cwd.XXXXXX")
  yazi $argv --cwd-file="$tmp"
  if set -f cwd (command cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
  cd -- "$cwd"
  end
  rm -f -- "$tmp"
end

