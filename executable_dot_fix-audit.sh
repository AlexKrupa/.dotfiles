#!/usr/bin/env bash
# Fixes the findings of the trust audit and reports Homebrew drift. Safe to run again: the battery
# app can add its sudoers rule back on an update. The script runs no sudo. It prints the steps that
# need sudo at the end.
set -euo pipefail

YELLOW='\033[1;33m' # switching section
GRAY='\033[1;30m'   # info
PURPLE='\033[1;35m' # making change
RED='\033[1;31m'    # needs sudo
NC='\033[0m'        # no color

info()   { echo -e "${GRAY}---- $1${NC}"; }
step()   { echo -e "\n${YELLOW}---- $1${NC}"; }
action() { echo -e "\n${PURPLE}---- $1${NC}"; }

# Each entry is a reason line, then the commands.
sudo_steps=()
needs_sudo() {
    info "Needs sudo, see the end"
    sudo_steps+=("$(printf '%s\n' "$@")")
}

BREWFILE="$HOME/.brewfile"
export HOMEBREW_NO_AUTO_UPDATE=1

##############################################################
# Root access
##############################################################

# setup.sh writes the root-owned copy and the new rule together, so a copy that matches Homebrew
# also means the new rule.
step "kanata sudoers rule"
KANATA_ROOT_BIN="/usr/local/kanata/kanata"
if ! command -v kanata &>/dev/null; then
    info "kanata not installed"
elif cmp -s "$(realpath "$(command -v kanata)")" "$KANATA_ROOT_BIN"; then
    info "The root-owned copy matches Homebrew"
else
    needs_sudo "kanata: old sudoers rule, or Homebrew upgraded kanata. The kanata setup script asks for sudo." \
        "$HOME/.config/kanata/setup.sh"
fi

# `battery update_silent` runs `curl .../main/update.sh | bash` as root, with no pin or hash. The
# battery.app GUI adds the rule back each time it opens: it treats a missing rule as a missing
# install and runs `curl .../main/setup.sh | bash` as root after a password prompt. The charge
# limit runs from the LaunchAgent and the CLI, so the GUI is not necessary.
step "battery sudoers rule"
# Only root can read the rule file, so the script cannot see if the rules are still there. The
# command does nothing when they are gone. sudo skips files in sudoers.d that have a dot in the
# name, so the new file is inactive until visudo accepts it.
BATTERY_SUDOERS="/etc/sudoers.d/battery"
if [ ! -e "$BATTERY_SUDOERS" ]; then
    info "battery not installed"
else
    needs_sudo "battery: remove the update_silent rules. Do not open battery.app, use the battery CLI." \
        "sudo sh -c 'f=$BATTERY_SUDOERS; grep -q update_silent \$f || exit 0; grep -v update_silent \$f > \$f.new && chmod 0440 \$f.new && visudo -cqf \$f.new && mv \$f.new \$f'"
fi

##############################################################
# Third-party taps with an official replacement
##############################################################

# homebrew/cask has `zulu@<version>` with the same Azul installer. Both casks install the same pkg,
# so the old cask goes first. The pkg installer needs sudo.
step "Zulu JDKs from the mdogan/zulu tap"
zulu_casks=$(brew list --cask --full-name | grep '^mdogan/zulu/' || true)
if [ -n "$zulu_casks" ]; then
    zulu_commands=()
    for cask in $zulu_casks; do
        zulu_commands+=("brew uninstall --cask $cask && brew install --cask zulu@${cask##*zulu-jdk}")
    done
    needs_sudo "Zulu: replace the mdogan/zulu casks, then remove the tap." \
        "${zulu_commands[@]}" "brew untap mdogan/zulu"
elif brew tap | grep -qx 'mdogan/zulu'; then
    action "Removing the mdogan/zulu tap"
    brew untap mdogan/zulu
else
    info "No casks from mdogan/zulu"
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

# The hellosverre-mods marketplace tracks a branch, so each push reaches Claude Code with no review.
# local-pins pins skins to a commit.
step "skins plugin"
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
    if marketplace_known hellosverre-mods; then
        action "Removing the hellosverre-mods marketplace"
        claude plugin marketplace remove hellosverre-mods
    fi
    info "skins checked"
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
# The dry run exits with 1 when it finds packages.
{ brew bundle cleanup --file "$BREWFILE" 2>/dev/null || true; } \
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
info "AirPlay Receiver: System Settings > General > AirDrop & Handoff. Set it to Current User, or turn it off."

##############################################################
# Firewall
##############################################################

# LuLu blocks only outgoing connections. Stealth mode does not answer pings and port scans.
step "Firewall"
FIREWALL="/usr/libexec/ApplicationFirewall/socketfilterfw"
if "$FIREWALL" --getglobalstate | grep -q 'State = [12]' && "$FIREWALL" --getstealthmode | grep -q ' on$'; then
    info "Firewall and stealth mode are on"
else
    needs_sudo "Firewall: turn it on, with stealth mode." \
        "sudo $FIREWALL --setglobalstate on" \
        "sudo $FIREWALL --setstealthmode on"
fi

##############################################################
# Steps that need sudo
##############################################################

if [ ${#sudo_steps[@]} -gt 0 ]; then
    step "Run these in a shell with sudo"
    for sudo_step in "${sudo_steps[@]}"; do
        echo -e "\n${RED}${sudo_step%%$'\n'*}${NC}"
        echo "${sudo_step#*$'\n'}"
    done
fi

##############################################################
# Agent prompt for the checks that a script cannot do
##############################################################

step "Prompt for a Claude Code agent on this computer"
cat <<'PROMPT'
Do a read-only trust and security audit of this Mac. ~/.fix-audit.sh already ran. Report
findings in a table, ranked by risk. Change nothing until I approve each item.

Rules:
- A disabled plugin, MCP server, or tool is not unused: I enable some per project. Before you call
  an item unused, search ~/src, ~/.config, key bindings, and scripts for it. If it is not clearly
  unused, ask me.
- Do not print secret values. Print only file names, key names, and counts.
- I have sudo only on request. Give me the sudo commands, do not run them.

Check:
1. Root access: files in /etc/sudoers.d (ask me to run `sudo cat`), LaunchDaemons, and
   privileged helpers that run code from a user-writable path or download code.
2. Browser extensions (Chrome, Edge, Firefox): owner changes, broad permissions such as
   <all_urls>, Manifest V2 extensions in Chromium browsers, abandoned extensions.
3. Raycast extensions with broad access or no recent updates.
4. Claude Code: plugins and marketplaces that track a branch, MCP servers that run
   `npx ...@latest`, hooks, and the permission allow list in ~/.claude/settings.json.
5. Shell and editor plugins: fish `fish_plugins` pins, nvim plugins, and PATH order. Homebrew
   and system paths must come before language tool folders (cargo, go, npm).
6. Secrets: run `gitleaks git --redact` on the chezmoi source repo. Look for tokens in shell
   history, credential files (~/.npmrc, ~/.netrc, ~/.aws, ~/.docker), and agent transcripts.
7. Network: services that listen on all interfaces (`lsof -nP -iTCP -sTCP:LISTEN`), the firewall
   state, and signed apps that the firewall allows with no prompt.
8. Apps from small or unknown publishers, apps with no updates for 2 or more years, and
   duplicates of tools that I already have.
PROMPT
