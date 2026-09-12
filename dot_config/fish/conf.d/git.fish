abbr -a g git
abbr -a lg lazygit
alias gs "git-spice"
alias gitc "$EDITOR $XDG_CONFIG_HOME/git/config-base"
alias giti "$EDITOR $XDG_CONFIG_HOME/git/ignore"

set -gx GIT_SPICE_NO_GS_WARNING 1

# Usage: branch [name...]
function branch --description 'List branches or create prefixed branch'
  if test (count $argv) -eq 0
    git branch --sort=-committerdate
  else
    git checkout -b "$(whoami).$(string join '-' $argv | string replace -a ' ' '-').$(date +%Y-%m-%d)"
  end
end

function catch-up --description 'Checkout and pull main branch'
  set -l main (__git_main)
  or return 1
  git checkout $main
  and git pull --prune
end

function cd-git-root --description 'Navigate to repository root'
  cd $(git rev-parse --show-toplevel)
end

function gco --wraps="git checkout" --description 'Checkout branch or default to main'
  if test (count $argv) -gt 0
    git checkout $argv
  else
    set -l main (__git_main)
    or return 1
    git checkout $main
  end
end

function gbf --description 'Fuzzy find and preview branches'
  git for-each-ref --format='%(refname:short)' --sort=-committerdate refs/heads | fzf --preview "git show {}"
end

function rebase --description 'Rebase current branch onto main'
  set -l main (__git_main)
  or return 1
  git checkout $main
  and git pull --prune
  and git checkout -
  and git rebase $main
end

function rm-merged-local --description 'Delete local branches merged to main'
  set -l main (__git_main)
  or return 1
  git branch --merged $main --format='%(refname:short)' \
    | string match --invert $main \
    | xargs -r git branch -d
end

function __git_main
  for branch in "main" "master" "trunk"
    if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null
      echo $branch
      return 0
    end
  end
  echo "No main, master or trunk branch found." >&2
  return 1
end

