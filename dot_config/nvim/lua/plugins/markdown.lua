return {
  -- Binds many plain keys (<CR>, <Tab>, +/-, o/O) in markdown buffers only.
  -- See `:help mkdnflow-mappings` for the full list.
  {
    'jakewvincent/mkdnflow.nvim',
    opts = {
      modules = {
        bib = false,
      },
      links = { style = 'markdown' },
      tables = { type = 'pipe' },
      mappings = {
        -- The default <leader>f shadows the [F]ormat which-key prefix.
        -- <leader>z* also matches the ideavim fold keys.
        MkdnFoldSection = { 'n', '<leader>zc' },
        MkdnUnfoldSection = { 'n', '<leader>zo' },
        -- The default <leader>p collides with the vimrc paste mappings.
        MkdnCreateLinkFromClipboard = { { 'n', 'v' }, '<leader>pp' },
      },
    },
  },

  {
    'iamcco/markdown-preview.nvim',
    cmd = { 'MarkdownPreviewToggle', 'MarkdownPreview', 'MarkdownPreviewStop' },
    ft = { 'markdown' },
    build = function()
      require('lazy').load { plugins = { 'markdown-preview.nvim' } }
      vim.fn['mkdp#util#install']()
    end,
    keys = {
      { '<leader>mp', '<cmd>MarkdownPreviewToggle<cr>', desc = 'Markdown preview (browser)' },
    },
  },

  {
    'MeanderingProgrammer/render-markdown.nvim',
    -- neo-tree already supplies nvim-web-devicons.
    dependencies = { 'nvim-treesitter/nvim-treesitter' },
    ft = { 'markdown' },
    keys = {
      { '<leader>mr', '<cmd>RenderMarkdown toggle<cr>', desc = 'Toggle [m]arkdown [r]endering' },
    },
    ---@module 'render-markdown'
    ---@type render.md.UserConfig
    opts = {
      enabled = true,
      preset = 'none', -- or 'obsidian', 'lazy'
      render_modes = true, -- all modes, or a list like { 'n', 'c', 't' }
    },
  },
}
