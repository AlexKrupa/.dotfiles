vim.cmd 'source ~/.config/vim/vimrc'

-- Load per-repo `.nvim.lua` config.
vim.o.exrc = true

-- Must be set before plugins load.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.g.have_nerd_font = true

vim.opt.number = true
vim.opt.relativenumber = true

vim.opt.wrap = false

vim.opt.confirm = true

vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true

vim.opt.mouse = 'a'

-- The mode is in the status line.
vim.opt.showmode = false

-- Deferred: setting the clipboard at startup is slow.
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

vim.opt.breakindent = true

vim.opt.undofile = true

vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.signcolumn = 'yes'

vim.opt.updatetime = 250
vim.opt.timeoutlen = 300

vim.opt.splitright = true
vim.opt.splitbelow = true

vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live.
vim.opt.inccommand = 'split'

vim.opt.cursorline = true

vim.opt.scrolloff = 10

vim.opt.hlsearch = true
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
  if vim.v.shell_error ~= 0 then
    error('Error cloning lazy.nvim:\n' .. out)
  end
end

---@type vim.Option
local rtp = vim.opt.rtp
rtp:prepend(lazypath)

require('lazy').setup({
  { import = 'plugins' },

  'NMAC427/guess-indent.nvim',

  -- `gc` comments a visual region or a line.
  { 'numToStr/Comment.nvim', opts = {} },

  {
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
  },

  {
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>ff',
        function()
          -- qmk.nvim owns keymap.c formatting. clangd reformats the grid.
          if vim.api.nvim_buf_get_name(0):match 'keymap%.c$' then
            return
          end
          require('conform').format { async = true, lsp_format = 'fallback' }
        end,
        mode = '',
        desc = '[F]ormat buffer',
      },
    },
    opts = {
      notify_on_error = false,
      format_on_save = function(bufnr)
        -- These languages have no standard style.
        local disable_filetypes = { c = true, cpp = true }
        if disable_filetypes[vim.bo[bufnr].filetype] then
          return nil
        else
          return {
            timeout_ms = vim.g.conform_timeout_ms or 500,
            lsp_format = 'fallback',
          }
        end
      end,
      formatters_by_ft = {
        lua = { 'stylua' },
        markdown = { 'prettier' },
      },
      formatters = {
        -- Prettier has no global config. Pass the shared CLI config.
        prettier = {
          prepend_args = { '--config', vim.fn.expand '~/.config/prettier/config.json', '--parser', 'markdown' },
        },
      },
    },
  },

  {
    'mfussenegger/nvim-lint',
    event = { 'BufReadPost', 'BufWritePost', 'InsertLeave' },
    config = function()
      local lint = require 'lint'
      lint.linters_by_ft = { markdown = { 'markdownlint-cli2' } }

      -- One config file in this repo, so the rules apply in every project.
      lint.linters['markdownlint-cli2'].args = {
        '--config',
        vim.fn.stdpath 'config' .. '/markdownlint.jsonc',
        '--',
      }

      vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWritePost', 'InsertLeave' }, {
        callback = function()
          require('lint').try_lint()
        end,
      })
    end,
  },

  {
    'Mofiqul/dracula.nvim',
    -- Load at startup, before the other plugins.
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme 'dracula'

      vim.cmd.hi 'Comment gui=none'
    end,
  },

  {
    'folke/todo-comments.nvim',
    event = 'VimEnter',
    dependencies = { 'nvim-lua/plenary.nvim' },
    opts = { signs = false },
  },

  {
    'echasnovski/mini.nvim',
    config = function()
      -- Around/inside textobjects: `va)`, `yinq`, `ci'`.
      require('mini.ai').setup { n_lines = 500 }

      local statusline = require 'mini.statusline'
      statusline.setup()

      -- Cursor location as LINE:COLUMN.
      ---@diagnostic disable-next-line: duplicate-set-field
      statusline.section_location = function()
        return '%2l:%-2v'
      end
    end,
  },

  {
    'gennaro-tedesco/nvim-jqx',
    event = { 'BufReadPost' },
    ft = { 'json', 'yaml' },
  },

  {
    'nguyenvukhang/nvim-toggler',
    event = 'VeryLazy',
    opts = {
      remove_default_keybinds = true,
    },
    keys = {
      {
        '<C-s>',
        function()
          require('nvim-toggler').toggle()
        end,
        mode = 'n',
        desc = 'Toggle word',
      },
    },
  },

  {
    'mg979/vim-visual-multi',
    branch = 'master',
    event = 'VeryLazy',
    init = function()
      vim.g.VM_maps = {
        ['Find Under'] = '<C-n>',
        ['Find Subword Under'] = '<C-n>',
        ['Select All'] = '<Leader><C-n>',
        ['Skip Region'] = '<C-x>',
        ['Remove Region'] = '<C-p>',
      }
    end,
  },

  {
    -- tpope grammar, same as ideavim: ys{motion}{char}, yss, ds{char},
    -- cs{target}{replacement}, visual S{char}.
    'kylechui/nvim-surround',
    version = '*',
    event = 'VeryLazy',
    opts = {},
  },

  {
    'nvim-neo-tree/neo-tree.nvim',
    branch = 'v3.x',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'nvim-tree/nvim-web-devicons',
      'MunifTanjim/nui.nvim',
    },
    cmd = 'Neotree',
    keys = {
      { '<leader>tp', '<cmd>Neotree toggle<cr>', desc = 'Toggle file tree' },
      { '<leader>tf', '<cmd>Neotree reveal<cr>', desc = 'Reveal current file in tree' },
    },
    opts = {
      filesystem = {
        follow_current_file = { enabled = true },
        hijack_netrw_behavior = 'open_current',
      },
      window = {
        mappings = {
          ['<esc>'] = function()
            vim.cmd 'wincmd p'
          end,
        },
      },
    },
  },

  {
    'folke/zen-mode.nvim',
    cmd = 'ZenMode',
    keys = {
      { '<leader>zz', '<cmd>ZenMode<cr>', desc = 'Toggle zen mode' },
    },
    opts = {
      window = {
        width = 120,
        options = {
          number = false,
          relativenumber = true,
        },
      },
    },
  },
}, {
  rocks = { hererocks = false },
})

local opts = { noremap = true, silent = true }

vim.keymap.set('n', '<leader>fj', '<Cmd>%!jq<CR>', opts)
vim.keymap.set('n', '<leader>fcj', '<Cmd>%!jq --compact-output<CR>', opts)

vim.keymap.set('v', '<leader>fj', ":'<,'>!jq<CR>", opts)

-- IdeaVim parity for the mappings below.
vim.keymap.set('n', 'gb', '<C-o>', { desc = 'Go back' })
vim.keymap.set('n', 'gf', '<C-i>', { desc = 'Go forward' })

vim.keymap.set('n', '<A-o>', 'o<Esc>k', { desc = 'Insert line below without entering insert mode' })
vim.keymap.set('n', '<A-O>', 'O<Esc>j', { desc = 'Insert line above without entering insert mode' })

vim.keymap.set('n', '<leader>/', '<cmd>vsplit<CR>', { desc = 'Split vertically' })
vim.keymap.set('n', '<leader>-', '<cmd>split<CR>', { desc = 'Split horizontally' })
vim.keymap.set('n', '<leader>=', '<cmd>only<CR>', { desc = 'Close all other splits' })

vim.keymap.set('n', 'gd', '<cmd>Telescope lsp_definitions<CR>', { desc = 'Go to definition' })
vim.keymap.set('n', 'gD', '<cmd>Telescope lsp_type_definitions<CR>', { desc = 'Go to type definition' })
vim.keymap.set('n', 'ge', vim.diagnostic.goto_next, { desc = 'Go to next error' })
vim.keymap.set('n', 'gE', vim.diagnostic.goto_prev, { desc = 'Go to previous error' })
vim.keymap.set('n', 'gh', vim.lsp.buf.hover, { desc = 'Show hover info' })
vim.keymap.set('n', 'gi', vim.lsp.buf.code_action, { desc = 'Show code actions' })
vim.keymap.set('n', 'gI', '<cmd>Telescope lsp_implementations<CR>', { desc = 'Go to implementation' })
vim.keymap.set('n', 'gl', vim.lsp.buf.hover, { desc = 'Quick doc (alias for hover)' })
vim.keymap.set('n', 'gp', '<cmd>Neotree reveal<CR>', { desc = 'Reveal file in tree' })
vim.keymap.set('n', 'gs', '<cmd>Telescope lsp_document_symbols<CR>', { desc = 'File structure' })
vim.keymap.set('n', 'gu', '<cmd>Telescope lsp_references<CR>', { desc = 'Show usages' })
vim.keymap.set('n', 'gy', vim.diagnostic.open_float, { desc = 'Show error description' })

vim.keymap.set('n', '<leader>fa', vim.lsp.buf.code_action, { desc = 'Code actions' })
vim.keymap.set('v', '<leader>fa', vim.lsp.buf.code_action, { desc = 'Code actions' })
vim.keymap.set('n', '<leader>fn', vim.lsp.buf.rename, { desc = 'Rename symbol' })
vim.keymap.set('n', '<leader>fo', function()
  vim.lsp.buf.code_action {
    context = { only = { 'source.organizeImports' } },
    apply = true,
  }
end, { desc = 'Organize imports' })

-- `@` file mentions in claude-prompt-*.md buffers.
require 'claude'

vim.keymap.set('i', '<S-CR>', '<CR>', { desc = 'Shift+Enter acts as Enter' })
