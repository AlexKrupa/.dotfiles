function __brew_quit_app --argument-names app_name --description 'Quit an app, force-kill if it ignores the quit'
    echo "Quitting $app_name..."
    osascript -e "tell application \"$app_name\" to quit" 2>/dev/null
    sleep 1
    # -i because the executable name often differs in case from the .app name (Handy/handy)
    if pgrep -xiq "$app_name"
        echo "Force-killing $app_name..."
        pkill -xi "$app_name" 2>/dev/null
        sleep 1
    end
end

function __brew_tagged_casks --argument-names tag --description 'Parse `cask:AppName:bundle.id` entries tagged in ~/.brewfile'
    for line in (grep "# $tag:" ~/.brewfile | grep -v '^#')
        set -l cask_name (string match -r 'cask "([^"]+)"' $line)[2]
        set -l metadata (string match -r "# $tag:\s*(.+)" $line)[2]
        if test -n "$cask_name" -a -n "$metadata"
            # `brew outdated` reports tap-qualified casks (user/tap/name) by bare name
            echo (path basename $cask_name):$metadata
        end
    end
end

function __brew_upgrade_cask --argument-names cask_name app_name bundle_id --description 'Upgrade a cask, quitting and restarting the app if it runs'
    if not pgrep -xiq "$app_name"
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
        return
    end

    __brew_quit_app $app_name
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $cask_name
    echo "Restarting $app_name..."
    open -b "$bundle_id" -g
end

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
    #
    # --greedy compares Caskroom metadata, not the app on disk, so self-updating casks
    # (firefox, google-chrome) report as outdated on every run until brew reinstalls them.
    # Without a tty the prompts read empty and those casks are left outdated.

    # Upgrade formulae first (no app restart needed)
    HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --formula

    set -l outdated_verbose (brew outdated --cask --greedy --verbose)
    set -l outdated_casks (string split ' ' -f1 -- $outdated_verbose)
    if test -z "$outdated_casks"
        brew cleanup
        return
    end

    set -l restart_entries
    for entry in (__brew_tagged_casks restart-on-upgrade)
        if contains -- (string split ':' $entry)[1] $outdated_casks
            set -a restart_entries $entry
        end
    end

    set -l prompt_entries
    for entry in (__brew_tagged_casks prompt-on-upgrade)
        if contains -- (string split ':' $entry)[1] $outdated_casks
            set -a prompt_entries $entry
        end
    end

    # Tagged casks are upgraded one at a time below, so keep them out of the bulk upgrade
    set -l tagged_casks (string replace -r ':.*' '' -- $restart_entries $prompt_entries)
    set -l bulk_casks
    for cask in $outdated_casks
        if not contains -- $cask $tagged_casks
            set -a bulk_casks $cask
        end
    end

    echo
    printf '  %s\n' $outdated_verbose
    test -n "$bulk_casks"; and echo "  bulk:           $bulk_casks"
    test -n "$restart_entries"; and echo "  quit + restart: "(string join ' ' (string replace -r ':.*' '' -- $restart_entries))
    test -n "$prompt_entries"; and echo "  ask first:      "(string join ' ' (string replace -r ':.*' '' -- $prompt_entries))
    echo

    if test -n "$bulk_casks"
        HOMEBREW_NO_INSTALL_CLEANUP=true brew upgrade --cask $bulk_casks
    end

    for entry in $restart_entries
        __brew_upgrade_cask (string split ':' $entry)
    end

    # A cask upgrade force-quits a running app (via the cask's `uninstall quit:` directive),
    # so for running apps we must ask BEFORE upgrading.
    for entry in $prompt_entries
        set -l parts (string split ':' $entry)
        if pgrep -xiq "$parts[2]"
            read -l -P "$parts[1]: $parts[2] is running; upgrading will close it. Upgrade and restart now? [y/N] " confirm
            if not string match -riq '^y$' -- $confirm
                echo "Skipping $parts[1] (left outdated)."
                continue
            end
        end
        __brew_upgrade_cask $parts
    end

    brew cleanup
end

function brew-kill --description 'Remove Homebrew lock files'
  rm -rf $(brew --prefix)/var/homebrew/locks
end

eval "$(/opt/homebrew/bin/brew shellenv)"
