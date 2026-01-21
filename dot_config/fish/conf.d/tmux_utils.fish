# File name is tmux-utils.fish instead of tmux.fish to avoid conflict with tmux.fish plugin (https://github.com/budimanjojo/tmux.fish)

# Run a command in a new tmux pane.
function tmux_split
  set -l command $argv
  # Count the number of panes in the current window
  set -l pane_count (tmux list-panes | wc -l)

  # Determine the ID of the last pane in the current window
  set -l last_pane_id (tmux list-panes -F '#{pane_id}' | tail -n 1)

  # If only one pane exists, split horizontally; otherwise, split vertically below the rightmost pane
  if test $pane_count -eq 1
    tmux split-window -dh -t $last_pane_id "fish -c '$command; cat'"
    # tmux select-layout even-horizontal
  else
    tmux split-window -dv -t $last_pane_id "fish -c '$command; cat'"
    # tmux select-layout even-vertical
  end

  # Resize panes only after the second pane has been created
  if test $pane_count -ge 2
    tmux select-layout tiled
  end
end

status is-interactive; and begin
    set fish_tmux_autostart true
end

alias tmuxc "$EDITOR $XDG_CONFIG_HOME/tmux/tmux.conf"
alias tmuxr "tmux source-file $XDG_CONFIG_HOME/tmux/tmux.conf"
alias tms tmux-split

