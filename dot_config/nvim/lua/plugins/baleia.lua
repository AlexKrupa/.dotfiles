return {
  { -- ANSI escape-code colorizer for log buffers
    'm00qek/baleia.nvim',
    -- Lazy: load only when a log file appears, either by extension or filetype.
    ft = 'log',
    event = { 'BufReadPre *.log', 'BufNewFile *.log' },
    config = function()
      local baleia = require('baleia').setup {}

      -- Guard: .log files match both the pattern autocmd and the FileType
      -- autocmd; attach baleia at most once per buffer.
      local function attach(buf)
        if vim.b[buf].baleia_attached then
          return
        end
        vim.b[buf].baleia_attached = true
        baleia.once(buf) -- colorize content already in the buffer
        baleia.automatically(buf) -- keep colorizing appended/tailed lines
      end

      vim.api.nvim_create_autocmd({ 'BufWinEnter' }, {
        pattern = '*.log',
        callback = function(ev)
          attach(ev.buf)
        end,
      })

      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'log',
        callback = function(ev)
          attach(ev.buf)
        end,
      })

      -- lazy.nvim refires the load-triggering event after config(), so the
      -- buffer that caused loading is caught by the autocmds above.
    end,
  },
}
