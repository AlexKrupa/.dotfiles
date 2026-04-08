#!/usr/bin/env bash

YELLOW='\033[1;33m' # switching section
GRAY='\033[1;30m'   # info
PURPLE='\033[1;35m' # making change
NC='\033[0m'        # no color

info()   { echo -e "${GRAY}---- $1${NC}"; }
step()   { echo -e "\n${YELLOW}---- $1${NC}"; }
action() { echo -e "\n${PURPLE}---- $1${NC}"; }

##############################################################
# Basics
##############################################################

action "Check for Apple software updates and restart your computer"

step "Installing Xcode command line tools"
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate --install -a --verbose
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

step "Setting up Homebrew"
if ! command -v brew &>/dev/null; then
    action "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
    info "Homebrew already installed"
fi

info "Disabling Homebrew analytics"
brew analytics off

step "Setting up GitHub"
brew install gh
if gh auth status &>/dev/null; then
    info "Already logged into GitHub"
else
    action "Log into GitHub - follow the prompts"
    gh auth login
fi

step "Setting up dotfiles with chezmoi"
brew install chezmoi
if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    info "chezmoi source already initialized"
    chezmoi update
else
    chezmoi init --apply https://github.com/AlexKrupa/.dotfiles.git
fi

step "Requesting admin password upfront"
sudo -v

##############################################################
# Fish shell
##############################################################

step "Installing Fish"
brew install fish

if [[ $(uname -p) == 'arm' ]]; then
    FISH_PATH="/opt/homebrew/bin/fish"
else
    FISH_PATH="/usr/local/bin/fish"
fi

if grep -Fxq "$FISH_PATH" /etc/shells; then
    info "Fish already registered in /etc/shells"
else
    info "Registering Fish in /etc/shells"
    echo "$FISH_PATH" | sudo tee -a /etc/shells
fi

if [[ "fish" == $(basename "${SHELL}") ]]; then
    info "Default shell already Fish"
else
    info "Setting default shell to Fish"
    chsh -s "$FISH_PATH"
fi

step "Setting up Fisher (Fish plugin manager)"
fish -c '
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
    fisher install jorgebucaran/fisher
    fisher update
'

##############################################################
# Misc
##############################################################

source "$HOME/.brew.sh"
"$(brew --prefix)/opt/fzf/install"
source "$HOME/.macos.sh"
# source "$HOME/.cleanup.sh"  # run manually if needed
