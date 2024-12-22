#!/usr/bin/env bash

# Based on Kaushik Gopal's dotfiles
# https://github.com/kaushikgopal/dotfiles/blob/c0ce216a8029dc00ea9338a2d498f8cc1c967c7f/.setup.sh

# switching section
YELLOW='\033[1;33m'
# info
GRAY='\033[1;30m'
# making change
PURPLE='\033[1;35m'
# No Color
NC='\033[0m'

##############################################################
# Basics (git & dotfiles)
##############################################################

echo -e "\n\n\n${PURPLE}---- Check for Apple Software Updates then restart your computer. \n Have you done this (no seriously!)${NC}"

echo -e "\n\n\n${YELLOW}---- installing Xcode command tools (without all of Xcode)${NC}"
touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress;
softwareupdate --install -a --verbose
rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
# install xcode
# xcode-select --install

echo -e "${YELLOW}---- setting up Homebrew${NC}"

if ! command -v brew &>/dev/null; then
  echo -e "\n\n\n${YELLOW}---- Homebrew not found. Installing...${NC}"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  echo -e "${GRAY}---- Homebrew is already installed.${NC}"
fi

echo -e "${GRAY}---- Turning Homebrew analytics off.${NC}"
brew analytics off

echo -e "${YELLOW}---- setting up Git${NC}"
brew install git

echo -e "${YELLOW}---- setting up GitHub${NC}"
brew install gh
gh auth status &> tmp_gh_login.txt
if grep -om1 "Logged in" tmp_gh_login.txt; then
    rm -f tmp_gh_login.txt
    echo -e "${GRAY}---- logged in to github${NC}"
else
    rm -f tmp_gh_login.txt
    echo -e "${PURPLE}---- you need to setup GitHub, follow the prompts now ${NC}"
    gh auth login
fi

echo -e "${YELLOW}---- setting up dotfiles${NC}"
cd $HOME

if git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${GRAY}---- looks like dotfile repo is setup${NC}"
else
    echo -e "${PURPLE}---- setting up home to point to dotfiles${NC}"
    git init -b master
    git remote add origin https://github.com/AlexKrupa/.dotfiles.git
    git fetch origin
    git reset --hard origin/master
fi

git config --global credential.helper osxkeychain

echo -e "${YELLOW}---- Asking for an admin password upfront${NC}"
sudo -v

function delete_if_exists {
    if [ -f "$1" ]; then
        # echo -e "$1 exists."
        echo -e "${PURPLE}---- $1 present, so deleting${NC}"
        sudo rm "$1"
    # else
        # echo -e "$1 does not exist."
    fi
}

function clone_if_absent {
    if [ ! -d "$1" ]; then
        echo -e "${PURPLE}---- $1 not present, so cloning${NC}"
        git clone $2 $1
    else
        echo -e "${GRAY}---- $1 already present. pulling latest version${NC}"
        cd $1
        git pull
        cd ..
    fi
}

# echo -e "${GRAY}---- delete native git if it exists${NC}"
# # sudo rm -rf /usr/bin/git
# delete_if_exists /etc/paths.d/git
# delete_if_exists /etc/manpaths.d/git
# # sudo pkgutil --forget --pkgs=GitOSX\.Installer\.git[A-Za-z0-9]*\.[a-z]*.pkg

##############################################################
# Fish shell
##############################################################

brew install fish

echo -e "\n\n\n${YELLOW}---- Setting up Fish${NC}"
if [[ $(uname -p) == 'arm' ]]; then
    if grep -Fxq "/opt/homebrew/bin/fish" /etc/shells; then
        echo -e "${GRAY}---- fish declaration present${NC}"
    else
        echo "/opt/homebrew/bin/fish" | sudo tee -a /etc/shells
    fi
else
    if grep -Fxq "/usr/local/bin/fish" /etc/shells; then
        echo -e "${GRAY}---- fish declaration present${NC}"
    else
        echo "/usr/local/bin/fish" | sudo tee -a /etc/shells
    fi
fi

if [[ "fish" == $(basename "${SHELL}") ]]; then
    echo -e "${GRAY}---- default shell is fish${NC}"
else
    echo -e "${GRAY}---- default shell is NOT fish${NC}"
    if [[ $(uname -p) == 'arm' ]]; then
        chsh -s /opt/homebrew/bin/fish
    else
        chsh -s /usr/local/bin/fish
    fi
fi

echo -e "${GRAY}---- symlink fish_history ${NC}"
trash ~/.local/share/fish/fish_history
ln -s $XDG_DATA_HOME/fish/fish_history ~/.local/share/fish/

echo -e "${YELLOW}---- Setting up Fisher (Fish plugin manager)${NC}"
curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
fisher install jorgebucaran/fisher # plugin manager
fisher install edc/bass # easier Bash in Fish
fisher install patrickf1/fzf.fish # fzf keybindings
fisher install patrickf1/colored_man_pages.fish
fisher install budimanjojo/tmux.fish # tmux integration (e.g. autostart)
fisher install gazorby/fish-abbreviation-tips # show exisiting alias when using full command
fisher install franciscolourenco/done # show notification when command is done, use with `brew install terminal-notifier`
fisher install orefalo/grc # colorize output of commands, requires `brew install grc`

##############################################################
# DEV
##############################################################


echo -e "${GRAY}---- moving home${NC}"
cd ~

echo -e "\n\n\n${YELLOW}---- Install rbenv/ruby${NC}"
# installs the same ruby version as homebrew just installed via vim
rbenv install -s $(brew info ruby | awk 'NR==1{print $3}')
rbenv global $(brew info ruby | awk 'NR==1{print $3}')
# now pin ruby to this version, so it doesn't change on you with brew update
brew pin ruby
# install bundler and gem stuff
# do this on a new terminal
gem install bundler

# echo -e "\n\n\n${YELLOW}---- setup for python development${NC}"
python setup
pyenv install --list
pyenv install 3.10.1
ln -s -f /usr/local/bin/python3 /usr/local/bin/python


## tmux
brew install tmux
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

##############################################################
# MISC.
##############################################################


source $HOME/.brew.sh
$(brew --prefix)/opt/fzf/install
# source $HOME/.macos.sh
# source $HOME/.cleanup.sh

unset delete_if_exists;
unset clone_if_absent;
