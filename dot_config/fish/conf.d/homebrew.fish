function brew-update
  brew update -q
  echo && brew outdated --greedy
end

function brew-upgrade
  HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --greedy
  brew cleanup
end

# Terminate Brew update in case it gets stuck.
function brew-kill
  rm -rf $(brew --prefix)/var/homebrew/locks
end

eval "$(/opt/homebrew/bin/brew shellenv)"
