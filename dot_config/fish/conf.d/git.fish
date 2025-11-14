function __git_main
  for branch in "main" "master" "trunk"
    if git rev-parse "$branch" &>/dev/null
      echo $branch
      break
    end
  end
end

function branch
  if test (count $argv) -eq 0
    git branch --sort=-committerdate
  else
    git checkout -b "$(whoami).$(string join '-' $argv | string replace -a ' ' '-').$(date +%Y-%m-%d)"
  end
end

function gco --wraps="git checkout"
  if test (count $argv) -gt 0
    git checkout $argv
  else
    git checkout (__git_main)
  end
end

function gbf
  git for-each-ref --format='%(refname:short)' --sort=-committerdate refs/heads | fzf --preview "git show {}"
end

function rebase
  set main (__git_main)
  git checkout $main
  and git pull --prune
  and git checkout -
  and git rebase $main
end

function catch-up
  git checkout (__git_main)
  and git pull --prune
end

function rm-merged-local
  set main (__git_main)
  git branch --merged $main | command grep -v $main | xargs git branch -D
end

function cd-git-root
  cd $(git rev-parse --show-toplevel)
end

# git-spice completions (branch stacking)
eval "$(gs shell completion fish)"

alias g "git"
alias lg "lazygit"
alias gitc "$EDITOR ~/.gitconfig-base"

