function chezmoi-work
    chezmoi --source ~/.local/share/chezmoi-work \
            --config ~/.config/chezmoi-work/chezmoi.toml \
            --cache ~/.cache/chezmoi-work \
            $argv
end

function chezmoi-update-all
    echo "Updating personal dotfiles..."
    chezmoi update
    echo "Updating work dotfiles..."
    chezmoi-work update
end
