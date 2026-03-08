function chezmoi-work
    chezmoi --source ~/.local/share/chezmoi-work \
            --config ~/.config/chezmoi-work/chezmoi.toml \
            --cache ~/.cache/chezmoi-work \
            $argv
end

function chezmoi-apply-all
    echo "Applying personal dotfiles..."
    chezmoi apply
    echo "Applying work dotfiles..."
    chezmoi-work apply
end
