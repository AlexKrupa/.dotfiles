function brew-update --description 'Update Homebrew and show outdated'
  brew update -q
  echo && brew outdated --greedy
end

function brew-upgrade --description 'Upgrade all packages, restart accessibility apps'
    # Some apps (e.g. AltTab, LinearMouse, BetterTouchTool) hook into accessibility or
    # input-monitoring APIs to intercept mouse/trackpad/keyboard events. If brew replaces
    # the binary while the app is running, macOS may revoke its permissions or the app may
    # crash - leaving input blocked or unresponsive until the app is relaunched.
    # To avoid this, we quit tagged apps before upgrading and restart them after.
    # Tag casks in ~/.brewfile (prefix with ! to temporarily disable):
    #   restart-on-upgrade: AppName:bundle.id - auto quit/restart
    #   prompt-on-upgrade: AppName:bundle.id  - upgrade, prompt to restart if running

    # Upgrade formulae first (no app restart needed)
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --formula

    # Parse apps that need quit/restart from Brewfile metadata
    set -l restart_apps
    for line in (grep '# restart-on-upgrade:' ~/.brewfile | grep -v '!restart-on-upgrade' | grep -v '^#')
        set -l cask_name (string match -r 'cask "([^"]+)"' $line)[2]
        set -l metadata (string match -r '# restart-on-upgrade:\s*(.+)' $line)[2]
        if test -n "$metadata" -a -n "$cask_name"
            set -a restart_apps "$cask_name:$metadata"
        end
    end

    # Parse apps that prompt before restart
    set -l prompt_apps
    for line in (grep '# prompt-on-upgrade:' ~/.brewfile | grep -v '!prompt-on-upgrade' | grep -v '^#')
        set -l cask_name (string match -r 'cask "([^"]+)"' $line)[2]
        set -l metadata (string match -r '# prompt-on-upgrade:\s*(.+)' $line)[2]
        if test -n "$metadata" -a -n "$cask_name"
            set -a prompt_apps "$cask_name:$metadata"
        end
    end

    # Get outdated casks once (reused for both non-tagged and tagged upgrades)
    set -l outdated_casks (brew outdated --cask --greedy --quiet)

    # Collect tagged cask names for exclusion from bulk upgrade
    set -l tagged_casks
    for entry in $restart_apps
        set -a tagged_casks (string split ':' $entry)[1]
    end
    for entry in $prompt_apps
        set -a tagged_casks (string split ':' $entry)[1]
    end

    # Upgrade non-tagged outdated casks
    set -l bulk_casks
    for cask in $outdated_casks
        if not contains $cask $tagged_casks
            set -a bulk_casks $cask
        end
    end
    if test (count $bulk_casks) -gt 0
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $bulk_casks
    end
    for entry in $restart_apps
        set -l cask_name (string split ':' $entry)[1]

        if not contains $cask_name $outdated_casks
            continue
        end
        set -l app_name (string split ':' $entry)[2]
        set -l bundle_id (string split ':' $entry)[3]

        if not pgrep -xq "$app_name"
            HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
            continue
        end

        echo "Quitting $app_name..."
        osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
        sleep 1
        if pgrep -xq "$app_name"
            echo "Force-killing $app_name..."
            killall "$app_name" 2>/dev/null
            sleep 1
        end

        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name

        echo "Restarting $app_name..."
        open -b "$bundle_id" -g
    end

    # Upgrade prompt-on-upgrade casks, ask before restarting running apps
    for entry in $prompt_apps
        set -l cask_name (string split ':' $entry)[1]

        if not contains $cask_name $outdated_casks
            continue
        end
        set -l app_name (string split ':' $entry)[2]
        set -l bundle_id (string split ':' $entry)[3]

        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name

        if pgrep -xq "$app_name"
            read -l -P "Restart $app_name? [y/N] " confirm
            if string match -riq '^y$' -- $confirm
                echo "Quitting $app_name..."
                osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
                sleep 1
                if pgrep -xq "$app_name"
                    echo "Force-killing $app_name..."
                    killall "$app_name" 2>/dev/null
                    sleep 1
                end
                echo "Restarting $app_name..."
                open -b "$bundle_id" -g
            end
        end
    end

    brew cleanup
end

function brew-kill --description 'Remove Homebrew lock files'
  rm -rf $(brew --prefix)/var/homebrew/locks
end

eval "$(/opt/homebrew/bin/brew shellenv)"
