return {
  { -- Diff review, inline or side-by-side (`t` toggles)
    'esmuellert/codediff.nvim',
    cmd = 'CodeDiff',
    opts = {
      -- Dracula's `DiffAdd` is bright green with dark text, which hides the syntax colors
      highlights = {
        line_insert = '#2a4034',
        line_delete = '#4a2a32',
        char_insert = '#3f6b4c',
        char_delete = '#7a3a45',
      },
      diff = {
        layout = 'inline',
        cycle_hunks_across_files = true,
      },
      explorer = {
        auto_open_on_cursor = true,
        focus_on_select = true,
        view_mode = 'tree',
      },
    },
  },
}
