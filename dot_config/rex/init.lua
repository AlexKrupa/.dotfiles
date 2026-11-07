-- Migrated from Herdr (~/.config/herdr/config.toml). Prefix: ctrl+space.

-- Send the prefix key to programs that use it.
rex.bind("ctrl+space>ctrl+space", "pane.send_key", { key = "ctrl+space" })

rex.bind("ctrl+space>s", "client.settings")

-- Workspaces
rex.bind("ctrl+space>g", "session.switch")
rex.bind("ctrl+space>w", "session.switch")
rex.bind("alt+s", "session.switch")
rex.bind("ctrl+space>shift+n", "session.new")
rex.bind("ctrl+space>shift+w", "session.rename")
rex.bind("ctrl+space>shift+d", "session.close")
rex.bind("alt+e", "session.previous")
rex.bind("alt+r", "session.next")

-- Tabs
rex.bind("ctrl+space>c", "client.tab.new")
rex.bind("alt+t", "client.tab.new")
rex.bind("ctrl+space>shift+t", "client.tab.rename")
rex.bind("alt+n", "client.tab.rename")
rex.bind("ctrl+space>p", "client.tab.previous")
rex.bind("alt+shift+e", "client.tab.previous")
rex.bind("ctrl+space>n", "client.tab.next")
rex.bind("alt+shift+r", "client.tab.next")
rex.bind("ctrl+space>1", "client.tab.goto", { index = 1 })
rex.bind("ctrl+space>2", "client.tab.goto", { index = 2 })
rex.bind("ctrl+space>3", "client.tab.goto", { index = 3 })
rex.bind("ctrl+space>4", "client.tab.goto", { index = 4 })
rex.bind("ctrl+space>5", "client.tab.goto", { index = 5 })
rex.bind("ctrl+space>6", "client.tab.goto", { index = 6 })
rex.bind("ctrl+space>7", "client.tab.goto", { index = 7 })
rex.bind("ctrl+space>8", "client.tab.goto", { index = 8 })
rex.bind("ctrl+space>9", "client.tab.goto", { index = 9 })
rex.bind("alt+shift+1", "client.tab.goto", { index = 1 })
rex.bind("alt+shift+2", "client.tab.goto", { index = 2 })
rex.bind("alt+shift+3", "client.tab.goto", { index = 3 })
rex.bind("alt+shift+4", "client.tab.goto", { index = 4 })
rex.bind("alt+shift+5", "client.tab.goto", { index = 5 })
rex.bind("alt+shift+6", "client.tab.goto", { index = 6 })
rex.bind("alt+shift+7", "client.tab.goto", { index = 7 })
rex.bind("alt+shift+8", "client.tab.goto", { index = 8 })
rex.bind("alt+shift+9", "client.tab.goto", { index = 9 })
rex.bind("ctrl+space>shift+x", "client.tab.close")
rex.bind("alt+shift+w", "client.tab.close")

-- Panes
rex.bind("ctrl+space>h", "pane.focus", { direction = "left" })
rex.bind("alt+h", "pane.focus", { direction = "left" })
rex.bind("ctrl+space>j", "pane.focus", { direction = "down" })
rex.bind("alt+j", "pane.focus", { direction = "down" })
rex.bind("ctrl+space>k", "pane.focus", { direction = "up" })
rex.bind("alt+k", "pane.focus", { direction = "up" })
rex.bind("ctrl+space>l", "pane.focus", { direction = "right" })
rex.bind("alt+l", "pane.focus", { direction = "right" })
rex.bind("ctrl+space>shift+h", "pane.move", { direction = "left" })
rex.bind("alt+shift+h", "pane.move", { direction = "left" })
rex.bind("ctrl+space>shift+j", "pane.move", { direction = "down" })
rex.bind("alt+shift+j", "pane.move", { direction = "down" })
rex.bind("ctrl+space>shift+k", "pane.move", { direction = "up" })
rex.bind("alt+shift+k", "pane.move", { direction = "up" })
rex.bind("ctrl+space>shift+l", "pane.move", { direction = "right" })
rex.bind("alt+shift+l", "pane.move", { direction = "right" })
rex.bind("ctrl+space>z", "pane.zoom")
rex.bind("alt+z", "pane.zoom")
rex.bind("ctrl+alt+h", "pane.resize", { direction = "left" })
rex.bind("ctrl+alt+j", "pane.resize", { direction = "down" })
rex.bind("ctrl+alt+k", "pane.resize", { direction = "up" })
rex.bind("ctrl+alt+l", "pane.resize", { direction = "right" })
rex.bind("ctrl+space>tab", "pane.focus_next")
rex.bind("ctrl+space>shift+tab", "pane.focus_previous")
rex.bind("ctrl+space>v", "pane.split", { direction = "right" })
rex.bind("alt+/", "pane.split", { direction = "right" })
rex.bind("ctrl+space>-", "pane.split", { direction = "down" })
rex.bind("alt+-", "pane.split", { direction = "down" })
rex.bind("ctrl+space>x", "pane.close")
rex.bind("alt+w", "pane.close")
rex.bind("alt+=", "pane.balance")
rex.bind("alt+shift+t", "pane.move_to_new_tab")

-- Resize mode
rex.mode("resize", { exclusive = true })
rex.bind("resize/enter", "client.mode.exit")
rex.bind("resize/escape", "client.mode.exit")
rex.bind("ctrl+space>r", "client.mode.enter", { name = "resize" })
rex.bind("resize/left", "pane.resize", { direction = "left" })
rex.bind("resize/down", "pane.resize", { direction = "down" })
rex.bind("resize/up", "pane.resize", { direction = "up" })
rex.bind("resize/right", "pane.resize", { direction = "right" })

-- Client
rex.bind("ctrl+space>shift+r", "client.config.reload")
rex.bind("ctrl+space>b", "client.sidebar.toggle")

-- Agents, tuicr, nvim, and the watch pane
local home = os.getenv("HOME")
local terminal = "com.superlogical.terminal"
local shell = "com.superlogical.terminal.shell"

rex.bind("cmd+p", "pane.go_to")
rex.bind("alt+shift+s", "pane.go_to")

-- The cwd of the foreground program, else the directory that the block reported last.
local function block_cwd(block_id)
  local process = rex.block.call(terminal, "process", { block_id = block_id })
  if process and process.foreground and process.foreground.cwd then
    return process.foreground.cwd
  end
  local reported = rex.block.call(terminal, "pwd", { block_id = block_id })
  if not (reported and reported.pwd) then return nil end
  local path = reported.pwd:gsub("^file://[^/]*", "")
  return (path:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function split_right(ctx, label, options, focus)
  local _, err = rex.session.new_split{
    anchor_id = ctx.block_id,
    direction = "horizontal",
    side = "after",
    focus = focus,
    layout = { block = { flavor = shell, label = label, options = options } },
  }
  if err ~= nil then error(err, 0) end
end

-- The blocks of the window that has block_id, or nil.
local function window_blocks(block_id)
  local view, err = rex.session.view{}
  if err ~= nil then error(err, 0) end
  for _, window in ipairs(view.windows) do
    local blocks, found = {}, false
    for _, layer in ipairs(window.layers) do
      for _, block in ipairs(layer.blocks) do
        table.insert(blocks, block)
        if block.block_id == block_id then found = true end
      end
    end
    if found then return blocks end
  end
  return nil
end

rex.action{
  name = "watch_pane",
  title = "Watch Pane",
  description = "A pane with the notifications of the watch daemon watchd",
  run = function(ctx)
    split_right(ctx, "watch", { command = { home .. "/.config/rex/watch.sh" } }, false)
  end,
}

rex.action{
  name = "nvim_toggle",
  title = "Toggle nvim Pane",
  run = function(ctx)
    for _, block in ipairs(window_blocks(ctx.block_id) or {}) do
      if block.label == "nvim" then
        local _, err = rex.call("block.close",
          { session_id = ctx.session_id, block_id = block.block_id })
        if err ~= nil then error(err, 0) end
        return
      end
    end
    split_right(ctx, "nvim", { command = { "nvim" }, cwd = block_cwd(ctx.block_id) }, true)
  end,
}
rex.bind("alt+d", "nvim_toggle")

-- After a server restart, Rex restores the blocks with their labels, but not their programs.
-- mux.sh agent-start gives an agent block the label "<kind>: <name>".
rex.action{
  name = "resume_agents",
  title = "Resume Claude Agents",
  run = function(ctx)
    local view, err = rex.session.view{}
    if err ~= nil then error(err, 0) end
    for _, window in ipairs(view.windows) do
      for _, layer in ipairs(window.layers) do
        for _, block in ipairs(layer.blocks) do
          if (block.label or ""):sub(1, 7) == "claude:" then
            rex.block.call(terminal, "write",
              { block_id = block.block_id, data = "claude --continue\r" })
          end
        end
      end
    end
  end,
}

-- The server has PATH=/usr/bin:/bin:/usr/sbin:/sbin and no REX_* variables. bin/mux.sh needs them.
local rex_bin_dir = home .. "/Library/Application Support/com.superlogical.rex/RexServer"
  .. "/Versions/Current/Rex Server.app/Contents/MacOS"
local function tuicr(mode)
  return function(ctx)
    local result, err = rex.exec({ home .. "/.config/agents/bin/tuicr.sh", mode, ctx.block_id }, {
      env = {
        PATH = home .. "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        REX_SESSION = ctx.session_id,
        REX_BLOCK = ctx.block_id,
        REX_BIN_DIR = rex_bin_dir,
      },
      timeout = 30,
    })
    if err ~= nil then error(err, 0) end
    if not result.ok then error(result.stderr, 0) end
  end
end
rex.action{ name = "tuicr_branch", title = "tuicr: Review Branch", run = tuicr("branch") }
rex.action{ name = "tuicr_send", title = "tuicr: Send Comments", run = tuicr("send") }
rex.action{ name = "tuicr_mr", title = "tuicr: Target Selector", run = tuicr("mr") }
rex.bind("alt+a", "tuicr_branch")
rex.bind("alt+shift+a", "tuicr_send")
rex.bind("ctrl+alt+a", "tuicr_mr")
