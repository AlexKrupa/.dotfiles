return {
  { -- Search and jump labels, same as the ideavim flash plugin
    'folke/flash.nvim',
    event = 'VeryLazy',
    opts = {
      search = {
        mode = 'exact',
        incremental = true,
      },
      label = {
        distance = true,
        min_pattern_length = 0, -- show labels immediately
        rainbow = {
          enabled = true,
          shade = 5, -- 1 to 9
        },
        uppercase = false,
      },
      modes = {
        char = {
          enabled = false, -- keep f/F/t/T as vim defaults
        },
      },
      jump = {
        autojump = true,
        nohlsearch = false,
      },
      highlight = {
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
        -- Visual S is left to nvim-surround, same as ideavim.
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
