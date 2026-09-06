return {
  -- Mkdnflow: in-markdown navigation, links, lists, tables, to-dos, folds.
  -- Loads only in markdown buffers. Binds many plain keys plus <leader> table
  -- ops, all buffer-local to markdown, so they don't touch global maps.
  --
  -- Active bindings (markdown buffers only):
  --   <CR>            follow/create link, fold section, or extend list
  --   <BS> / <Del>    buffer back / forward
  --   <Tab> / <S-Tab> next / prev link (normal); next / prev table cell (insert)
  --   ]] / [[         next / prev heading
  --   ][ / []         next / prev same-level heading
  --   + / -           increase / decrease heading   (g+ / g-  operator versions)
  --   <M-CR>          destroy link (n) / tag span (v) / prev table row (i)
  --   <C-Space>       cycle to-do status
  --   o / O           new list item below / above (falls back to normal o/O)
  --   <C-t> / <C-d>   indent / dedent list item (insert)
  --   yaa / yfa       yank anchor link / file-anchor link
  --   <F2>            rename / move linked file
  --   <leader>pp      create link from clipboard
  --   <leader>nn      renumber ordered list
  --   <leader>ir / iR table row below / above
  --   <leader>ic / iC table col after / before
  --   <leader>dr / dc delete table row / col
  --   <leader>al / ar / ac / ax  align col left / right / center / default
  --   <leader>zc / zo fold / unfold section  (moved off default <leader>f/<leader>F)
  -- Disabled: bib citation following.
  {
    'jakewvincent/mkdnflow.nvim',
    opts = {
      modules = {
        bib = false, -- not using bibliographies
      },
      links = { style = 'markdown' },
      tables = { type = 'pipe' },
      mappings = {
        -- Default fold keys are plain <leader>f / <leader>F; <leader>f would
        -- shadow the [F]ormat which-key prefix in markdown buffers. Move folds
        -- onto <leader>z* to match IdeaVim (<leader>za / <leader>zc) folds.
        MkdnFoldSection = { 'n', '<leader>zc' },
        MkdnUnfoldSection = { 'n', '<leader>zo' },
        -- Default <leader>p collides with vimrc: visual <leader>p = paste, and
        -- <leader>pi / <leader>pu make it a prefix. Move to <leader>pp.
        MkdnCreateLinkFromClipboard = { { 'n', 'v' }, '<leader>pp' },
      },
    },
  },

  -- Markdown Preview: Browser-based markdown preview
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

  -- Render Markdown: in-editor rendered view (headings, code blocks, tables,
  -- checkboxes, etc.)
  --
  -- Toggle: <leader>mr  (or :RenderMarkdown toggle)
  {
    'MeanderingProgrammer/render-markdown.nvim',
    -- treesitter already loaded; nvim-web-devicons (via neo-tree) supplies icons.
    dependencies = { 'nvim-treesitter/nvim-treesitter' },
    ft = { 'markdown' },
    keys = {
      { '<leader>mr', '<cmd>RenderMarkdown toggle<cr>', desc = 'Toggle [m]arkdown [r]endering' },
    },
    ---@module 'render-markdown'
    ---@type render.md.UserConfig
    opts = {
      enabled = true,
      -- Style preset. Options: 'none', 'obsidian', 'lazy'.
      preset = 'none',
      -- Modes showing the rendered view. true = all modes (renders even while
      -- editing in insert/visual). Use a list like { 'n', 'c', 't' } to limit.
      render_modes = true,
    },
  },
}
