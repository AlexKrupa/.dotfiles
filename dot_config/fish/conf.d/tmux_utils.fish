# File name is tmux_utils.fish instead of tmux.fish to avoid conflict with tmux.fish plugin (https://github.com/budimanjojo/tmux.fish)

function tmux-split --description 'Run a command in a new tmux pane'
  if test (count $argv) -lt 1
    echo "Usage: tmux-split <command>" >&2
    return 1
  end

  set -l command "$argv"
  set -l pane_count (tmux list-panes | wc -l)

  set -l last_pane_id (tmux list-panes -F '#{pane_id}' | tail -n 1)

  if test $pane_count -eq 1
    tmux split-window -dh -t $last_pane_id fish -c "$command; cat"
  else
    tmux split-window -dv -t $last_pane_id fish -c "$command; cat"
  end

  if test $pane_count -ge 2
    tmux select-layout tiled
  end
end

status is-interactive; and begin
    set -g fish_tmux_autostart false
end

alias tmuxc "$EDITOR ~/.config/tmux/tmux.conf"
alias tmuxr "tmux source-file ~/.config/tmux/tmux.conf"
alias tms tmux-split

