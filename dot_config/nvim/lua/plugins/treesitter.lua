return {
  {
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

      vim.api.nvim_create_autocmd('FileType', {
        callback = function(args)
          if pcall(vim.treesitter.start, args.buf) then
            -- Ruby needs the regex indent.
            if vim.bo[args.buf].filetype ~= 'ruby' then
              vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
            end
          end
        end,
      })
    end,
  },
}
