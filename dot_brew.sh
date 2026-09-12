#!/usr/bin/env bash

YELLOW='\033[1;33m'
NC='\033[0m'

step() { echo -e "\n${YELLOW}---- $1${NC}"; }

step "Installing apps from Brewfile"
brew bundle install --file "$HOME/.brewfile"
