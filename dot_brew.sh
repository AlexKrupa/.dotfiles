#!/usr/bin/env bash

# Brew Apps installed from Brewfile
echo "${ARROW}Installing apps from Brewfile..."
brew bundle install --file Brewfile
