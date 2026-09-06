return {
  -- QMK keymap.c file formatter
  {
    'codethread/qmk.nvim',
    config = function()
      ---@type qmk.UserConfig
      local conf = {
        name = 'LAYOUT_voyager',
        comment_preview = {
          position = 'none',
        },
        layout = {
          'x x x x x x _ x x x x x x',
          'x x x x x x _ x x x x x x',
          'x x x x x x _ x x x x x x',
          'x x x x x x _ x x x x x x',
          '_ _ _ _ x x _ x x _ _ _ _',
        },
      }
      require('qmk').setup(conf)
    end,
  },
}
