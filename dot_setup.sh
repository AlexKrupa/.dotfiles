#!/usr/bin/env bash

# Based on Kaushik Gopal's dotfiles
# https://github.com/kaushikgopal/dotfiles/blob/c0ce216a8029dc00ea9338a2d498f8cc1c967c7f/.setup.sh

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

action "Check for Apple Software Updates then restart your computer. Have you done this (no seriously!)"

step "Installing Xcode command line tools"
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate --install -a --verbose
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

step "Setting up Homebrew"
if ! command -v brew &>/dev/null; then
    action "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
    info "Homebrew is already installed"
fi

info "Turning Homebrew analytics off"
brew analytics off

step "Setting up GitHub"
brew install gh
if gh auth status &>/dev/null; then
    info "Logged in to GitHub"
else
    action "You need to setup GitHub, follow the prompts now"
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

step "Asking for an admin password upfront"
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
    info "fish declaration present in /etc/shells"
else
    echo "$FISH_PATH" | sudo tee -a /etc/shells
fi

if [[ "fish" == $(basename "${SHELL}") ]]; then
    info "default shell is fish"
else
    info "default shell is NOT fish - switching"
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
