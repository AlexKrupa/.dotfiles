return {
  { -- Highlight, edit, and navigate code
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    lazy = false,
    build = ':TSUpdate',
    config = function()
      require('nvim-treesitter').setup {}
      require('nvim-treesitter').install {
        'bash',
        'c',
        'diff',
        'dockerfile',
        'editorconfig',
        'fish',
        'git_config',
        'git_rebase',
        'gitcommit',
        'gitignore',
        'go',
        'graphql',
        'html',
        'java',
        'javascript',
        'json',
        'json5',
        'kotlin',
        'lua',
        'luadoc',
        'markdown',
        'markdown_inline',
        'python',
        'query',
        'regex',
        'ruby',
        'swift',
        'toml',
        'typescript',
        'vim',
        'vimdoc',
        'xml',
        'yaml',
      }

      -- Highlighting and indentation are now built into Neovim's treesitter
      vim.api.nvim_create_autocmd('FileType', {
        callback = function(args)
          -- Enable treesitter highlighting if a parser is available
          if pcall(vim.treesitter.start, args.buf) then
            -- Enable treesitter indentation (except Ruby which needs regex-based indent)
            if vim.bo[args.buf].filetype ~= 'ruby' then
              vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            end
          end
        end,
      })
    end,
    -- There are additional nvim-treesitter modules that you can use to interact
    -- with nvim-treesitter. You should go explore a few and see what interests you:
    --
    --    - Incremental selection: Included, see `:help nvim-treesitter-incremental-selection-mod`
    --    - Show your current context: https://github.com/nvim-treesitter/nvim-treesitter-context
    --    - Treesitter + textobjects: https://github.com/nvim-treesitter/nvim-treesitter-textobjects
  },
}
