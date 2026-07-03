function prettierg --wraps prettier --description 'prettier with global config'
    prettier --config ~/.config/prettier/config.json $argv
end
