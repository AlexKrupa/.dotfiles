# git-spice completions (branch stacking)
eval "$(gs shell completion fish)"

alias g "git"
alias lg "lazygit"
alias gitc "$EDITOR ~/.gitconfig-base"

# Usage: branch [name...]
function branch --description 'List branches or create prefixed branch'
  if test (count $argv) -eq 0
    git branch --sort=-committerdate
  else
    git checkout -b "$(whoami).$(string join '-' $argv | string replace -a ' ' '-').$(date +%Y-%m-%d)"
  end
end

function catch-up --description 'Checkout and pull main branch'
  git checkout (__git_main)
  and git pull --prune
end

function cd-git-root --description 'Navigate to repository root'
  cd $(git rev-parse --show-toplevel)
end

function gco --wraps="git checkout" --description 'Checkout branch or default to main'
  if test (count $argv) -gt 0
    git checkout $argv
  else
    git checkout (__git_main)
  end
end

function gbf --description 'Fuzzy find and preview branches'
  git for-each-ref --format='%(refname:short)' --sort=-committerdate refs/heads | fzf --preview "git show {}"
end

function rebase --description 'Rebase current branch onto main'
  set main (__git_main)
  git checkout $main
  and git pull --prune
  and git checkout -
  and git rebase $main
end

function rm-merged-local --description 'Delete local branches merged to main'
  set main (__git_main)
  git branch --merged $main | command grep -v $main | xargs git branch -D
end

function __git_main
  for branch in "main" "master" "trunk"
    if git rev-parse "$branch" &>/dev/null
      echo $branch
      break
    end
  end
end

