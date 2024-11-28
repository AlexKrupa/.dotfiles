source ~/.config/fish/env.fish
source ~/.config/fish/alias.fish
source ~/.config/fish/colors.fish

if test -f ~/.config/fish/local.fish
  source ~/.config/fish/local.fish
end

java17 # default Java version
starship init fish | source
fish_vi_key_bindings # Vim mode, fish_default_key_bindings for default
fish_vi_cursor
fzf_configure_bindings
fx --comp fish | source

set -g fish_cursor_default block
set -g fish_cursor_insert line
set -g fish_cursor_replace_one underscore
set -g fish_cursor_visual block
# set -g fish_vi_force_cursor 1

# yy shell wrapper that provides the ability to change the current working directory when exiting Yazi.
# https://yazi-rs.github.io/docs/quick-start#shell-wrapper
function yy
	set tmp (mktemp -t "yazi-cwd.XXXXXX")
	yazi $argv --cwd-file="$tmp"
	if set cwd (command cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
		cd -- "$cwd"
	end
	rm -f -- "$tmp"
end
