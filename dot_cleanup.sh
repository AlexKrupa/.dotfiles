#!/usr/bin/env bash

YELLOW='\033[1;33m' # switching section
GRAY='\033[1;30m'   # info
PURPLE='\033[1;35m' # making change
NC='\033[0m'        # no color

info()   { echo -e "${GRAY}---- $1${NC}"; }
step()   { echo -e "\n${YELLOW}---- $1${NC}"; }
action() { echo -e "\n${PURPLE}---- $1${NC}"; }

delete_if_exists() {
    if [ -e "$1" ]; then
        info "Deleting $1"
        sudo rm -rf "$1" 2>/dev/null
    else
        info "$1 does not exist"
    fi
}

step "Running cleanup now"

action "Rebuilding launch services"
# Remove duplicates in the “Open With” menu (also see `lscleanup` alias)
# /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain user; and killall Finder
# /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user

# action "Safari caches"
# delete_if_exists ~/Library/Caches/com.apple.Safari

action "gradle caches"
find ~/.gradle/caches -type f -atime +30 -delete
find ~/.gradle/caches -type d -mindepth 1 -empty -delete

action "kscript jars"
delete_if_exists "$HOME/.kscript"

action ".android caches"
delete_if_exists "$HOME/.android/cache"
delete_if_exists "$HOME/.android/build-cache"

# action "CocoaPods"
# see flushpods.fish
# delete_if_exists $HOME/Library/Caches/CocoaPods

# action "Spotlight refresh"
# sudo mdutil -a -i off
# sudo launchctl unload -w /System/Library/LaunchDaemons/com.apple.metadata.mds.plist
# sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.metadata.mds.plist
# sudo mdutil -a -i on

# action "DNS flush"
# see flushdns.fish
dscacheutil -flushcache
sudo killall -HUP mDNSResponder

action "homebrew cleanup"
# brew outdated
# Remove stale lock files and outdated downloads for all formulae and casks
# remove old versions of installed formulae
brew cleanup

# make system mactch brewfile
# brew bundle --force cleanup --file=".brewfile"

# get rid of unused dependencies (used only at time of installation)
brew autoremove
brew doctor

# manual process
# https://thoughtbot.com/blog/brew-leaves
# brew leaves
