function __git_main
  for branch in "trunk" "main" "master"
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

function rebase
  set trunk (__git_main)
  git checkout $trunk
  and git pull --prune
  and git checkout -
  and git rebase $trunk
end

function catch-up
  git checkout (__git_main)
  and git pull --prune
end

function rm-merged-local
  set trunk (__git_main)
  git branch --merged $trunk | command grep -v $trunk | xargs git branch -D
end
