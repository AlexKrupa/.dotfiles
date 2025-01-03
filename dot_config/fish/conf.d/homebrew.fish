function brew-update
  brew update -q
  echo && brew outdated --greedy
end

function brew-upgrade
  HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --greedy
  brew cleanup
end

eval "$(/opt/homebrew/bin/brew shellenv)"
