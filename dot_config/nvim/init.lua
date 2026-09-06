vim.cmd 'source ~/.config/vim/vimrc'

-- Load local repo nvim lua configs
vim.o.exrc = true

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- [[ Setting options ]]
-- See `:help vim.opt`
-- NOTE: You can change these options as you wish!
--  For more options, you can see `:help option-list`

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, for help with jumping.
--  Experiment for yourself to see if you like it!
vim.opt.relativenumber = true

-- Disable text wrapping
vim.opt.wrap = false

-- Confirm dialog for unsaved changes
vim.opt.confirm = true

-- Set default indentation
vim.opt.tabstop = 2 -- Default tab width
vim.opt.shiftwidth = 2 -- Default indentation at each level
vim.opt.expandtab = true -- Convert tabs to spaces
vim.opt.smartindent = true -- syntax aware indentations for newline inserts

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in status line
vim.opt.showmode = false

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
  vim.opt.clipboard = 'unnamedplus'
end)

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or capital in search
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Set highlight on search, but clear on pressing <Esc> in normal mode
vim.opt.hlsearch = true
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.hl.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

-- [[ Install `lazy.nvim` plugin manager ]]
--    See `:help lazy.nvim.txt` or https://github.com/folke/lazy.nvim for more info
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

-- [[ Configure and install plugins ]]
--
--  To check the current status of your plugins, run
--    :Lazy
--
--  You can press `?` in this menu for help. Use `:q` to close the window
--
--  To update plugins, you can run
--    :Lazy update
--
-- NOTE: Here is where you install your plugins.
require('lazy').setup({
  -- Each file under `lua/plugins/` returns its own spec list.
  { import = 'plugins' },

  -- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
  'NMAC427/guess-indent.nvim', -- Detect tabstop and shiftwidth automatically

  -- NOTE: Plugins can also be added by using a table,
  -- with the first argument being the link and the following
  -- keys can be used to configure plugin behavior/loading/etc.
  --
  -- Use `opts = {}` to force a plugin to be loaded.
  --
  --  This is equivalent to:
  --    require('Comment').setup({})

  -- "gc" to comment visual regions/lines
  { 'numToStr/Comment.nvim', opts = {} },

  -- Here is a more advanced example where we pass configuration
  -- options to `gitsigns.nvim`. This is equivalent to the following lua:
  --    require('gitsigns').setup({ ... })
  --
  -- See `:help gitsigns` to understand what the configuration keys do
  { -- Adds git related signs to the gutter, as well as utilities for managing changes
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

  { -- Autoformat
    'stevearc/conform.nvim',
    event = { 'BufWritePre' },
    cmd = { 'ConformInfo' },
    keys = {
      {
        '<leader>ff',
        function()
          -- Skip QMK keymap files: clangd reformats the grid and we rely
          -- on qmk.nvim's own BufWritePre hook for those files.
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
        -- Disable "format_on_save lsp_fallback" for languages that don't
        -- have a well standardized coding style. You can add additional
        -- languages here or re-enable it for the disabled ones.
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
        -- Conform can also run multiple formatters sequentially
        -- python = { "isort", "black" },
        --
        -- You can use 'stop_after_first' to run the first available formatter from the list
        -- javascript = { "prettierd", "prettier", stop_after_first = true },
      },
      formatters = {
        -- Shared with CLI; prettier has no global config, so pass it explicitly.
        prettier = {
          prepend_args = { '--config', vim.fn.expand '~/.config/prettier/config.json', '--parser', 'markdown' },
        },
      },
    },
  },

  { -- Linting
    'mfussenegger/nvim-lint',
    event = { 'BufReadPost', 'BufWritePost', 'InsertLeave' },
    config = function()
      local lint = require 'lint'
      lint.linters_by_ft = { markdown = { 'markdownlint-cli2' } }

      -- Inline config: point markdownlint-cli2 at a single file we own,
      -- so rules live with this nvim config and apply regardless of project.
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

  { -- You can easily change to a different colorscheme.
    -- Change the name of the colorscheme plugin below, and then
    -- change the command in the config to whatever the name of that colorscheme is
    --
    -- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`
    -- 'folke/tokyonight.nvim',
    'Mofiqul/dracula.nvim',
    lazy = false, -- make sure we load this during startup if it is your main colorscheme
    priority = 1000, -- make sure to load this before all the other start plugins
    config = function()
      -- Load the colorscheme here
      -- vim.cmd.colorscheme 'tokyonight-night'
      vim.cmd.colorscheme 'dracula'

      -- You can configure highlights by doing something like
      vim.cmd.hi 'Comment gui=none'
    end,
  },

  -- Highlight todo, notes, etc in comments
  {
    'folke/todo-comments.nvim',
    event = 'VimEnter',
    dependencies = { 'nvim-lua/plenary.nvim' },
    opts = { signs = false },
  },

  { -- Collection of various small independent plugins/modules
    'echasnovski/mini.nvim',
    config = function()
      -- Better Around/Inside textobjects
      --
      -- Examples:
      --  - va)  - [V]isually select [A]round [)]paren
      --  - yinq - [Y]ank [I]nside [N]ext [']quote
      --  - ci'  - [C]hange [I]nside [']quote
      require('mini.ai').setup { n_lines = 500 }

      -- Simple and easy statusline.
      --  You could remove this setup call if you don't like it,
      --  and try some other statusline plugin
      local statusline = require 'mini.statusline'
      statusline.setup()

      -- You can configure sections in the statusline by overriding their
      -- default behavior. For example, here we set the section for
      -- cursor location to LINE:COLUMN
      ---@diagnostic disable-next-line: duplicate-set-field
      statusline.section_location = function()
        return '%2l:%-2v'
      end

      -- ... and there is more!
      --  Check out: https://github.com/echasnovski/mini.nvim
    end,
  },

  {
    'gennaro-tedesco/nvim-jqx',
    event = { 'BufReadPost' },
    ft = { 'json', 'yaml' },
  },

  -- Toggler: Toggle word variants (val/var, true/false, etc.)
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

  -- Visual Multi: Multiple cursors
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

  -- Surround: add/change/delete surrounding pairs.
  -- Defaults match ideavim's tpope/vim-surround: ys{motion}{char}, yss,
  -- ds{char}, cs{target}{replacement}, visual S{char}.
  {
    'kylechui/nvim-surround',
    version = '*',
    event = 'VeryLazy',
    opts = {},
  },

  -- Neo-tree: File explorer
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

  -- Zen Mode: Distraction-free coding
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

  -- The following two comments only work if you have downloaded the kickstart repo, not just copy pasted the
  -- init.lua. If you want these files, they are in the repository, so you can just download them and
  -- put them in the right spots if you want.

  -- NOTE: Next step on your Neovim journey: Add/Configure additional plugins for kickstart
  --
  --  Here are some example plugins that I've included in the kickstart repository.
  --  Uncomment any of the lines below to enable them (you will need to restart nvim).
  --
  -- require 'kickstart.plugins.debug',
  -- require 'kickstart.plugins.indent_line',
}, {
  rocks = { hererocks = false },
})

-- The line beneath this is called `modeline`. See `:help modeline`
-- vim: ts=2 sts=2 sw=2 et

--------------
-- MAPPINGS --
--------------

local opts = { noremap = true, silent = true }

-- jq: Whole buffer
vim.keymap.set('n', '<leader>fj', '<Cmd>%!jq<CR>', opts)
vim.keymap.set('n', '<leader>fcj', '<Cmd>%!jq --compact-output<CR>', opts)

-- jq: Visual selection
vim.keymap.set('v', '<leader>fj', ":'<,'>!jq<CR>", opts)

-- Back/forward navigation (consistent with IdeaVim)
vim.keymap.set('n', 'gb', '<C-o>', { desc = 'Go back' })
vim.keymap.set('n', 'gf', '<C-i>', { desc = 'Go forward' })

-- Alt+O for newlines (from vimrc:84-85)
vim.keymap.set('n', '<A-o>', 'o<Esc>k', { desc = 'Insert line below without entering insert mode' })
vim.keymap.set('n', '<A-O>', 'O<Esc>j', { desc = 'Insert line above without entering insert mode' })

-- Split management shortcuts (IdeaVim-style)
vim.keymap.set('n', '<leader>/', '<cmd>vsplit<CR>', { desc = 'Split vertically' })
vim.keymap.set('n', '<leader>-', '<cmd>split<CR>', { desc = 'Split horizontally' })
vim.keymap.set('n', '<leader>=', '<cmd>only<CR>', { desc = 'Close all other splits' })

-- Enhanced LSP mappings (IdeaVim-style g* shortcuts)
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

-- Refactoring and formatting actions (<leader>f prefix from IdeaVim)
vim.keymap.set('n', '<leader>fa', vim.lsp.buf.code_action, { desc = 'Code actions' })
vim.keymap.set('v', '<leader>fa', vim.lsp.buf.code_action, { desc = 'Code actions' })
vim.keymap.set('n', '<leader>fn', vim.lsp.buf.rename, { desc = 'Rename symbol' })
vim.keymap.set('n', '<leader>fo', function()
  vim.lsp.buf.code_action {
    context = { only = { 'source.organizeImports' } },
    apply = true,
  }
end, { desc = 'Organize imports' })

-- Claude Code: @ file mention support in claude-prompt-*.md buffers.
require 'claude'

-- Treat Shift+Enter like Enter in insert mode (don't leave insert mode)
vim.keymap.set('i', '<S-CR>', '<CR>', { desc = 'Shift+Enter acts as Enter' })
