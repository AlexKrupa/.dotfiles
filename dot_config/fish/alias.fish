# Configs
alias fisha "$EDITOR ~/.config/fish/alias.fish"
alias fishc "$EDITOR ~/.config/fish/config.fish"
alias fishcd "cd ~/.config/fish/conf.d/"
alias fishr "source ~/.config/fish/**/*.fish"
alias fishl "$EDITOR ~/.config/fish/local.fish"
alias fishe "$EDITOR ~/.config/fish/env.fish"
alias aerospacec "$EDITOR ~/.config/aerospace/aerospace.toml"
alias ghosttyc "$EDITOR ~/.config/ghostty/config"
alias gitc "$EDITOR ~/.gitconfig-base"
alias gradlep "$EDITOR ~/.gradle/gradle.properties"
alias gradlei "$EDITOR ~/.gradle/init.gradle"
alias ivimc "$EDITOR ~/.ideavimrc"
alias nvimc "$EDITOR ~/.config/nvim/init.lua"
alias tmuxc "$EDITOR ~/.tmux.conf"
alias tmuxr "tmux source-file ~/.tmux.conf"
alias vimc "$EDITOR ~/.vimrc"
alias weztermc "$EDITOR ~/.config/wezterm/wezterm.lua"

function cd-git-root
  cd $(git rev-parse --show-toplevel)
end

# walk file manager
function lk
  set loc (walk $argv); and cd $loc
end

# yy shell wrapper that provides the ability to change the current working directory when exiting Yazi.
# https://yazi-rs.github.io/docs/quick-start#shell-wrapper
function y
  set -l tmp (mktemp -t "yazi-cwd.XXXXXX")
  yazi $argv --cwd-file="$tmp"
  if set -f cwd (command cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
  cd -- "$cwd"
  end
  rm -f -- "$tmp"
end

# Run a command in a new tmux pane.
function tmux-split
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
alias tms tmux-split


################################################################################
## Tools
################################################################################


function jdk
  argparse 's/silent' -- $argv
  or return

  # This handles cases when --silent is passed as a first or second argument.
  set -l jdk_version $argv[-1]

  if test -n "$jdk_version"
    set -gx JAVA_HOME $(/usr/libexec/java_home -v "$jdk_version")
  else
    echo "Error: No JDK version specified." >&2  # Redirect to stderr
    return 1
  end

  if not set -q _flag_silent
    java -version
  end
end

## Other
alias brewkill "rm -rf $(brew --prefix)/var/homebrew/locks" # Terminate Brew update in case it gets stuck.
alias cd "z" # zoxide
alias g "git"
alias lg "lazygit"
alias ls "lsd --all --long --git --group-dirs=first"
alias dl "cd ~/Downloads"
alias dlf "open ~/Downloads"
alias finder "open ."

# Remove duplicates from $PATH and $fish_user_paths
function dedup_paths
  # Remove duplicates from $PATH
  set -l unique_path
  for path in $PATH
    if not contains $path $unique_path
      set unique_path $unique_path $path
    end
  end
  set -gx PATH $unique_path

  # Remove duplicates from $fish_user_paths
  set -l unique_fish_user_paths
  for path in $fish_user_paths
    if not contains $path $unique_fish_user_paths
      set unique_fish_user_paths $unique_fish_user_paths $path
    end
  end
  set -U fish_user_paths $unique_fish_user_paths
end
