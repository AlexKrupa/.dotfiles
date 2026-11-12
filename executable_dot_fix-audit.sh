#!/usr/bin/env bash
# Fixes the root findings of the trust audit and reports Homebrew drift. Safe to run again: the
# battery app can add its sudoers rule back on an update.
set -euo pipefail

YELLOW='\033[1;33m' # switching section
GRAY='\033[1;30m'   # info
PURPLE='\033[1;35m' # making change
NC='\033[0m'        # no color

info()   { echo -e "${GRAY}---- $1${NC}"; }
step()   { echo -e "\n${YELLOW}---- $1${NC}"; }
action() { echo -e "\n${PURPLE}---- $1${NC}"; }

BREWFILE="$HOME/.brewfile"
export HOMEBREW_NO_AUTO_UPDATE=1

##############################################################
# Root access
##############################################################

step "kanata sudoers rule"
KANATA_ROOT_BIN="/usr/local/kanata/kanata"
KANATA_SUDOERS="/etc/sudoers.d/kanata"
if ! command -v kanata &>/dev/null; then
    info "kanata not installed"
elif sudo grep -qF "NOPASSWD: $KANATA_ROOT_BIN -c " "$KANATA_SUDOERS" 2>/dev/null \
    && cmp -s "$(realpath "$(command -v kanata)")" "$KANATA_ROOT_BIN"; then
    info "Rule allows only the root-owned copy, and the copy matches Homebrew"
else
    action "Running kanata setup: old rule, or Homebrew upgraded kanata"
    "$HOME/.config/kanata/setup.sh"
fi

# `battery update_silent` runs `curl .../main/update.sh | bash` as root, with no pin or hash. The
# battery.app GUI adds the rule back each time it opens: it treats a missing rule as a missing
# install and runs `curl .../main/setup.sh | bash` as root after a password prompt. The charge
# limit runs from the LaunchAgent and the CLI, so the GUI is not necessary.
step "battery sudoers rule"
BATTERY_SUDOERS="/etc/sudoers.d/battery"
if ! sudo test -f "$BATTERY_SUDOERS"; then
    info "battery not installed"
elif sudo grep -q "update_silent" "$BATTERY_SUDOERS"; then
    action "Removing the update_silent rules from $BATTERY_SUDOERS"
    # sudo skips files in sudoers.d that have a dot in the name, so the new file is inactive until
    # the check passes.
    sudo sh -c "grep -v update_silent '$BATTERY_SUDOERS' > '$BATTERY_SUDOERS.new'"
    sudo chmod 0440 "$BATTERY_SUDOERS.new"
    sudo visudo -cqf "$BATTERY_SUDOERS.new"
    sudo mv "$BATTERY_SUDOERS.new" "$BATTERY_SUDOERS"
    info "Do not open battery.app. Use the battery CLI. After a battery update, run this script again."
else
    info "No update_silent rules"
fi

##############################################################
# Third-party taps with an official replacement
##############################################################

# homebrew/cask has `zulu@<version>` with the same Azul installer. Both casks install the same pkg,
# so the old cask goes first.
step "Zulu JDKs from the mdogan/zulu tap"
zulu_casks=$(brew list --cask --full-name | grep '^mdogan/zulu/' || true)
if [ -z "$zulu_casks" ]; then
    info "No casks from mdogan/zulu"
else
    for cask in $zulu_casks; do
        version=${cask##*zulu-jdk}
        action "Replacing $cask with zulu@$version"
        brew uninstall --cask "$cask"
        brew install --cask "zulu@$version"
    done
fi
if brew tap | grep -qx 'mdogan/zulu'; then
    action "Removing the mdogan/zulu tap"
    brew untap mdogan/zulu
fi

##############################################################
# Duplicates
##############################################################

# Android Studio and the shell must use the same adb. Two versions kill the server of each other.
step "adb from the android-platform-tools cask"
if ! brew list --cask android-platform-tools &>/dev/null; then
    info "Cask not installed"
elif [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
    action "Uninstalling the cask: the Android SDK has adb"
    brew uninstall --cask android-platform-tools
else
    info "No Android SDK adb, keeping the cask"
fi

##############################################################
# Claude Code plugins
##############################################################

# The removed marketplaces track a branch, so each push reached Claude Code with no review.
# local-pins pins skins to a commit.
step "Claude Code plugins"
PLUGINS_DIR="$HOME/.claude/plugins"
LOCAL_MARKETPLACE="$HOME/.claude/local-marketplace"

plugin_installed() { jq -e --arg id "$1" '.plugins | has($id)' "$PLUGINS_DIR/installed_plugins.json" &>/dev/null; }
marketplace_known() { jq -e --arg name "$1" 'has($name)' "$PLUGINS_DIR/known_marketplaces.json" &>/dev/null; }
# Claude Code names the store file of a plugin with the first 12 characters of the SHA-256 of the
# plugin ID.
store_file() { echo "$PLUGINS_DIR/store/${1/@/_}-$(printf '%s' "$1" | shasum -a 256 | cut -c1-12).json"; }

if ! command -v claude &>/dev/null; then
    info "Claude Code not installed"
elif plugin_installed skins@hellosverre-mods \
    && ! grep -q '"name": "skins"' "$LOCAL_MARKETPLACE/.claude-plugin/marketplace.json"; then
    info "local-pins has no skins entry. Run 'chezmoi update', then run this script again."
else
    if plugin_installed skins@hellosverre-mods; then
        action "Moving skins to local-pins"
        old_store=$(store_file skins@hellosverre-mods)
        new_store=$(store_file skins@local-pins)
        # The store keeps the chosen skin and its preferences.
        if [ -f "$old_store" ] && [ ! -e "$new_store" ]; then
            cp -p "$old_store" "$new_store"
        fi
        claude plugin uninstall skins@hellosverre-mods
        if marketplace_known local-pins; then
            claude plugin marketplace update local-pins
        else
            claude plugin marketplace add "$LOCAL_MARKETPLACE"
        fi
        claude plugin install skins@local-pins
        rm -f "$old_store"
    fi
    for plugin in ksrc@respawn-tools android-cli@android-cli-plugin nono@nolabs-ai; do
        plugin_installed "$plugin" || continue
        action "Uninstalling $plugin"
        claude plugin uninstall "$plugin"
    done
    for marketplace in hellosverre-mods respawn-tools android-cli-plugin nolabs-ai; do
        marketplace_known "$marketplace" || continue
        action "Removing the $marketplace marketplace"
        claude plugin marketplace remove "$marketplace"
    done
    info "Plugins checked"
fi

##############################################################
# Homebrew drift (report only)
##############################################################

installed_formulae=$(brew list --formula -1)
installed_casks=$(brew list --cask -1)
installed_full_names=$(brew list --full-name --formula; brew list --full-name --cask)

step "In the Brewfile, not installed"
while read -r name; do
    # `brew list` resolves aliases, for example 7zip to sevenzip. It is slow, so it runs only on a
    # miss.
    grep -qixF "${name##*/}" <<< "$installed_formulae" || brew list --formula "$name" &>/dev/null \
        || echo "formula $name"
done < <(brew bundle list --formula --file "$BREWFILE" 2>/dev/null)
while read -r name; do
    grep -qixF "${name##*/}" <<< "$installed_casks" || echo "cask $name"
done < <(brew bundle list --cask --file "$BREWFILE" 2>/dev/null)

step "Installed, not in the Brewfile (dependencies included)"
brew bundle cleanup --file "$BREWFILE" 2>/dev/null \
    | awk '/^Would uninstall/ { show = 1 } /^Would (untap|`brew cleanup`)/ { show = 0 } show'

# A tap with no installed package still gets pulled by `brew update`, and brew trusts its
# formula names.
step "Taps with no installed package, not in the Brewfile"
brewfile_taps=$(brew bundle list --tap --file "$BREWFILE" 2>/dev/null)
while read -r tap; do
    grep -qiF "$tap/" <<< "$installed_full_names" && continue
    grep -qixF "$tap" <<< "$brewfile_taps" && continue
    echo "$tap"
done < <(brew tap | grep -v '^homebrew/')

##############################################################
# Manual steps (report only)
##############################################################

step "Manual steps"
info "Raycast easydict: turn off the automatic query of selected text and the Chinese services, or remove it"
info "Raycast: uninstall meme-generator and 1-click-confetti"
