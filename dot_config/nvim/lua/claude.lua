vim.api.nvim_create_autocmd('BufEnter', {
  -- Tail-only pattern (no `/`) survives Claude Code changing TMPDIR.
  pattern = 'claude-prompt-*.md',
  callback = function(ev)
    if vim.b[ev.buf].claude_at_mapped then
      return
    end
    vim.b[ev.buf].claude_at_mapped = true

    vim.keymap.set('i', '@', function()
      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      local bufnr = vim.api.nvim_get_current_buf()

      -- Inside inline code, insert a literal @.
      if col > 0 then
        local char_before = vim.api.nvim_buf_get_text(bufnr, row - 1, col - 1, row - 1, col, {})[1]
        if char_before == '`' then
          vim.api.nvim_feedkeys('@', 'n', false)
          return
        end
      end

      vim.schedule(function()
        require('telescope.builtin').find_files {
          prompt_title = '@ File Reference',
          find_command = { 'fd', '--type', 'f', '--type', 'd', '--strip-cwd-prefix' },
          attach_mappings = function(prompt_bufnr, map)
            local actions = require 'telescope.actions'
            local action_state = require 'telescope.actions.state'

            actions.select_default:replace(function()
              local entry = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if entry then
                vim.schedule(function()
                  local text = '@' .. entry[1] .. ' '
                  vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { text })
                  vim.api.nvim_win_set_cursor(0, { row, col + #text })
                  vim.cmd 'startinsert'
                end)
              end
            end)

            local function cancel()
              actions.close(prompt_bufnr)
              vim.schedule(function()
                vim.api.nvim_buf_set_text(bufnr, row - 1, col, row - 1, col, { '@' })
                vim.api.nvim_win_set_cursor(0, { row, col + 1 })
                vim.cmd 'startinsert'
              end)
            end

            map('i', '<Esc>', cancel)
            map('n', '<Esc>', cancel)
            map('n', 'q', cancel)

            return true
          end,
        }
      end)
    end, { buffer = ev.buf, desc = 'Insert @file reference (Claude Code)' })
  end,
})
