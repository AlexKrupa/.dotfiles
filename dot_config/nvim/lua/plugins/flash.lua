return {
  -- Flash: Enhanced search and navigation (IdeaVim flash equivalent)
  {
    'folke/flash.nvim',
    event = 'VeryLazy',
    opts = {
      search = {
        mode = 'exact',
        incremental = true, -- Show matches as you type
      },
      label = {
        distance = true, -- for the current window, label targets closer to the cursor first
        -- minimum pattern length to show labels
        -- Ignored for custom labelers.
        min_pattern_length = 0, -- Show labels immediately
        -- Enable this to use rainbow colors to highlight labels
        -- Can be useful for visualizing Treesitter ranges.
        rainbow = {
          enabled = true,
          -- number between 1 and 9
          shade = 5,
        },
        uppercase = false, -- allow uppercase labels
      },
      modes = {
        char = {
          enabled = false, -- Disable single-char f/F/t/T replacement
        },
      },
      jump = {
        autojump = true, -- Automatically jump when there is only one match
        nohlsearch = false, -- Clear highlight after jump
      },
      highlight = {
        -- Highlight the search matches
        matches = true,
      },
    },
    keys = {
      {
        's',
        mode = { 'n', 'x', 'o' },
        function()
          require('flash').jump()
        end,
        desc = 'Flash',
      },
      {
        -- Visual S left to nvim-surround (tpope grammar), matching ideavim.
        'S',
        mode = { 'n', 'o' },
        function()
          require('flash').treesitter()
        end,
        desc = 'Flash Treesitter',
      },
      {
        'r',
        mode = 'o',
        function()
          require('flash').remote()
        end,
        desc = 'Remote Flash',
      },
    },
  },
}
