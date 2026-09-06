return {
  {
    'm00qek/baleia.nvim',
    ft = 'log',
    event = { 'BufReadPre *.log', 'BufNewFile *.log' },
    config = function()
      local baleia = require('baleia').setup {}

      -- A .log file matches both autocmds below. Attach once per buffer.
      local function attach(buf)
        if vim.b[buf].baleia_attached then
          return
        end
        vim.b[buf].baleia_attached = true
        baleia.once(buf) -- existing buffer content
        baleia.automatically(buf) -- appended lines
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

      -- lazy.nvim refires the load event after config(), so the autocmds above
      -- still catch the buffer that triggered the load.
    end,
  },
}
