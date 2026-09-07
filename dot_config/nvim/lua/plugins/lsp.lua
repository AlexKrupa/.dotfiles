return {
  {
    -- Lua LSP support for the nvim config, runtime and plugin APIs.
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    'neovim/nvim-lspconfig',
    -- Without a trigger this subtree (mason, fidget, blink.cmp) loads before the first paint.
    -- vim.lsp.enable() below still attaches to a file given on the command line.
    event = 'VeryLazy',
    dependencies = {
      -- Mason must load before its dependents.
      { 'mason-org/mason.nvim', opts = {} },
      'mason-org/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      { 'j-hui/fidget.nvim', opts = {} },

      'saghen/blink.cmp',
    },
    config = function()
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc, mode)
            mode = mode or 'n'
            vim.keymap.set(mode, keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          map('grn', vim.lsp.buf.rename, '[R]e[n]ame')

          map('gra', vim.lsp.buf.code_action, '[G]oto Code [A]ction', { 'n', 'x' })

          map('grr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences')

          map('gri', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')

          map('grd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')

          -- Declaration, not definition. In C this opens the header.
          map('grD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

          map('gO', require('telescope.builtin').lsp_document_symbols, 'Open Document Symbols')

          map('gW', require('telescope.builtin').lsp_dynamic_workspace_symbols, 'Open Workspace Symbols')

          map('grt', require('telescope.builtin').lsp_type_definitions, '[G]oto [T]ype Definition')

          map('K', vim.lsp.buf.hover, 'Hover Documentation')

          -- Resolves a difference between nvim 0.10 and 0.11.
          ---@param client vim.lsp.Client
          ---@param method vim.lsp.protocol.Method
          ---@param bufnr? integer some lsp support methods only in specific files
          ---@return boolean
          local function client_supports_method(client, method, bufnr)
            if vim.fn.has 'nvim-0.11' == 1 then
              return client:supports_method(method, bufnr)
            else
              return client.supports_method(method, { bufnr = bufnr })
            end
          end

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_documentHighlight, event.buf) then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end

          if client and client_supports_method(client, vim.lsp.protocol.Methods.textDocument_inlayHint, event.buf) then
            map('<leader>th', function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled { bufnr = event.buf })
            end, '[T]oggle Inlay [H]ints')
          end
        end,
      })

      vim.diagnostic.config {
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = vim.g.have_nerd_font and {
          text = {
            [vim.diagnostic.severity.ERROR] = '󰅚 ',
            [vim.diagnostic.severity.WARN] = '󰀪 ',
            [vim.diagnostic.severity.INFO] = '󰋽 ',
            [vim.diagnostic.severity.HINT] = '󰌶 ',
          },
        } or {},
        virtual_text = {
          source = 'if_many',
          spacing = 2,
          format = function(diagnostic)
            local diagnostic_message = {
              [vim.diagnostic.severity.ERROR] = diagnostic.message,
              [vim.diagnostic.severity.WARN] = diagnostic.message,
              [vim.diagnostic.severity.INFO] = diagnostic.message,
              [vim.diagnostic.severity.HINT] = diagnostic.message,
            }
            return diagnostic_message[diagnostic.severity]
          end,
        },
      }

      -- blink.cmp adds capabilities that nvim does not have by default.
      local capabilities = require('blink.cmp').get_lsp_capabilities()

      -- `intellij-server` reruns the Gradle import on every `initialize` and exits with its client.
      -- Keep one detached server per project root so a later reopen reuses the warm index.
      -- The cache in `~/Library/Caches/JetBrains/analyzer` is keyed by root path, so git worktrees
      -- of one repo need separate servers.
      local kotlin_lsp_host = '127.0.0.1'

      ---@return string workspace_key
      ---@return integer port
      local function kotlin_lsp_workspace(root_dir)
        local workspace_key = vim.fn.sha256(root_dir):sub(1, 12)
        return workspace_key, 20000 + tonumber(workspace_key:sub(1, 4), 16) % 20000
      end

      local function probe_port(port, on_result)
        local socket = assert(vim.uv.new_tcp())
        socket:connect(kotlin_lsp_host, port, function(err)
          socket:close()
          on_result(err == nil)
        end)
      end

      local function connect_kotlin_lsp(dispatchers, config)
        -- A wrong root imports the wrong project. Do not guess one.
        local root_dir = config.root_dir or error 'kotlin_lsp: no project root'
        local _, port = kotlin_lsp_workspace(root_dir)
        return vim.lsp.rpc.connect(kotlin_lsp_host, port)(dispatchers)
      end

      -- On an unbuilt Android project the server lists every missing `build/` artifact in one
      -- message, which forces a hit-enter prompt. Only generated code needs those artifacts.
      local function shorten_kotlin_lsp_message(err, result, ctx)
        local message = result and result.message
        if message and message:find("Couldn't resolve some dependencies", 1, true) then
          local _, count = message:gsub('Gradle: ', '')
          result = vim.tbl_extend('force', result, {
            message = ('%d unresolved artifacts (R, KSP need a build)'):format(count),
          })
        end
        return vim.lsp.handlers['window/showMessage'](err, result, ctx)
      end

      local servers = {
        clangd = {},
        gopls = {},
        gitlab_ci_ls = {},
        gradle_ls = {},
        graphql = {},
        groovyls = {},
        html = {},
        jdtls = {},
        kotlin_lsp = {
          cmd = connect_kotlin_lsp,
          handlers = { ['window/showMessage'] = shorten_kotlin_lsp_message },
        },
        ktfmt = {},

        lua_ls = {
          settings = {
            Lua = {
              runtime = { version = 'LuaJIT' },
              workspace = {
                checkThirdParty = false,
                library = {
                  '${3rd}/luv/library',
                  unpack(vim.api.nvim_get_runtime_file('', true)),
                },
              },
              completion = {
                callSnippet = 'Replace',
              },
            },
          },
        },

        pylsp = {},
        ts_ls = {},
        yamlls = {},
      }

      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua',
        'prettier',
        'markdownlint-cli2',
        'detekt', -- Kotlin linter
        'goimports',
        'jsonlint',
        'ktlint',
        'shfmt',
        'yamlfmt',
        'yamllint',
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      -- Register the per-server overrides before `mason-lspconfig` enables the installed servers.
      -- A server enabled first starts with the plain `nvim-lspconfig` defaults.
      vim.lsp.config('*', { capabilities = capabilities })
      for server_name, server in pairs(servers) do
        if next(server) ~= nil then
          vim.lsp.config(server_name, server)
        end
      end

      require('mason-lspconfig').setup {
        ensure_installed = {}, -- mason-tool-installer above owns the install list
        automatic_installation = false,
        -- A cold `intellij-server` needs minutes to accept a connection. `vim.lsp.enable` cannot
        -- wait for it. The `FileType` autocmd starts `kotlin_lsp` instead.
        automatic_enable = { exclude = { 'kotlin_lsp' } },
      }

      vim.lsp.enable(vim.tbl_filter(function(name)
        return name ~= 'kotlin_lsp'
      end, vim.tbl_keys(servers)))

      local function start_kotlin_lsp(root_dir, bufnr)
        if vim.api.nvim_buf_is_valid(bufnr) then
          local config = vim.tbl_extend('force', vim.lsp.config.kotlin_lsp, { root_dir = root_dir })
          vim.lsp.start(config, { bufnr = bufnr })
        end
      end

      local kotlin_lsp_booting = {}

      local function boot_kotlin_lsp(root_dir, bufnr)
        local workspace_key, port = kotlin_lsp_workspace(root_dir)
        if kotlin_lsp_booting[port] then
          return
        end
        kotlin_lsp_booting[port] = true

        local command = vim.fn.exepath 'intellij-server'
        if command == '' then
          command = vim.fn.expand '~/.local/share/nvim/mason/bin/intellij-server'
        end
        local log_path = vim.fn.stdpath 'state' .. '/kotlin-lsp-' .. workspace_key .. '.log'
        -- A detached job drops both pipes.
        local shell_command = ('exec %s --socket %s:%d --multi-client --system-path %s >%s 2>&1'):format(
          vim.fn.shellescape(command),
          kotlin_lsp_host,
          port,
          -- Without this, each run leaks a log tree in a new temp directory.
          vim.fn.shellescape(vim.fn.expand('~/.cache/kotlin-lsp/' .. workspace_key)),
          vim.fn.shellescape(log_path)
        )
        vim.fn.jobstart({ 'sh', '-c', shell_command }, { cwd = root_dir, detach = true })

        local timer = assert(vim.uv.new_timer())
        local deadline = vim.uv.now() + 300000
        timer:start(2000, 2000, function()
          probe_port(port, function(live)
            if timer:is_closing() then
              return
            end
            local expired = vim.uv.now() > deadline
            if not (live or expired) then
              return
            end
            timer:close()
            kotlin_lsp_booting[port] = nil
            vim.schedule(function()
              if live then
                start_kotlin_lsp(root_dir, bufnr)
              else
                vim.notify(('kotlin_lsp: no server on %s:%d for %s, see %s'):format(kotlin_lsp_host, port, root_dir, log_path), vim.log.levels.WARN)
              end
            end)
          end)
        end)
      end

      local function attach_kotlin_lsp(bufnr)
        -- A closer `build.gradle*` marks one module, not the repo root.
        local root_dir = vim.fs.root(bufnr, { 'settings.gradle.kts', 'settings.gradle', 'build.gradle.kts', 'build.gradle' })
        if not root_dir then
          return
        end
        local _, port = kotlin_lsp_workspace(root_dir)
        probe_port(port, function(live)
          vim.schedule(function()
            if live then
              start_kotlin_lsp(root_dir, bufnr)
            else
              boot_kotlin_lsp(root_dir, bufnr)
            end
          end)
        end)
      end

      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'kotlin',
        group = vim.api.nvim_create_augroup('kotlin-lsp-start', { clear = true }),
        callback = function(event)
          attach_kotlin_lsp(event.buf)
        end,
      })

      -- `FileType` already fired for a file named on the command line.
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].filetype == 'kotlin' then
          attach_kotlin_lsp(bufnr)
        end
      end
    end,
  },
}
