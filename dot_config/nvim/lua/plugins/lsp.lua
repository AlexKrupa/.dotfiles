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

      -- Each consumer of locations, for example Telescope, gets the sources from `kotlin_lsp_sources`,
      -- because the change is in the RPC client, not in a handler.
      local kotlin_lsp_location_methods = {
        ['textDocument/declaration'] = true,
        ['textDocument/definition'] = true,
        ['textDocument/implementation'] = true,
        ['textDocument/typeDefinition'] = true,
      }

      -- The wrapper finds the project root from its working directory.
      local function start_kotlin_lsp(dispatchers, config)
        local command = { vim.fn.expand '~/.local/wrappers/kotlin-lsp', '--stdio' }
        local rpc = vim.lsp.rpc.start(command, dispatchers, { cwd = config.root_dir })
        local request = rpc.request
        rpc.request = function(method, params, callback, notify_reply_callback)
          if not kotlin_lsp_location_methods[method] then
            return request(method, params, callback, notify_reply_callback)
          end
          return request(method, params, function(err, result)
            -- The sources search waits for `rg` and `unzip`, which a fast event cannot do.
            vim.schedule(function()
              callback(err, err == nil and require('kotlin_lsp_sources').to_sources(result, params, config.root_dir) or result)
            end)
          end, notify_reply_callback)
        end
        return rpc
      end

      -- A library file has no project root. It uses the server of the last Kotlin buffer, which is
      -- the buffer that the jump came from, so that a next jump inside the library also works.
      -- `#` cannot show that buffer, because the new buffer loads in a temporary window.
      local last_kotlin_lsp_root
      vim.api.nvim_create_autocmd({ 'BufEnter', 'LspAttach' }, {
        group = vim.api.nvim_create_augroup('kotlin-lsp-last-root', { clear = true }),
        callback = function(event)
          local client = vim.lsp.get_clients({ name = 'kotlin_lsp', bufnr = event.buf })[1]
          if client then
            last_kotlin_lsp_root = client.root_dir
          end
        end,
      })

      local function find_kotlin_lsp_root(bufnr, on_dir)
        if vim.startswith(vim.api.nvim_buf_get_name(bufnr), 'jar:') then
          if last_kotlin_lsp_root then
            on_dir(last_kotlin_lsp_root)
          end
          return
        end
        -- `jdtls` owns the Java files of a project. `java` is in `filetypes` for Java library files.
        if vim.bo[bufnr].filetype == 'java' then
          return
        end
        -- Each marker searches all parents before the next, so a module `build.gradle.kts` does not
        -- win over the repo `settings.gradle.kts`. Same order as `~/.local/wrappers/kotlin-lsp`.
        local root_dir = vim.fs.root(bufnr, { 'settings.gradle.kts', 'settings.gradle', 'build.gradle.kts', 'build.gradle' })
        if root_dir then
          on_dir(root_dir)
        end
      end

      -- kotlin-lsp gives a library symbol as `jar:///<jar path>!/<entry path>`: a source file in a
      -- sources jar, or a class file. Its `decompile` command returns no text for a source file.
      ---@return string text
      ---@return string? filetype
      local function read_kotlin_lsp_jar_entry(uri)
        local jar_path, entry_path = uri:match '^jar://(.-)!/(.+)$'
        if entry_path:match '%.kt$' or entry_path:match '%.java$' then
          local result = vim.system({ 'unzip', '-p', jar_path, entry_path }, { text = true }):wait()
          if result.code ~= 0 then
            error(('kotlin_lsp: cannot read %s from %s: %s'):format(entry_path, jar_path, result.stderr))
          end
          return result.stdout, vim.filetype.match { filename = entry_path }
        end
        local decompiled = require('kotlin_lsp_sources').decompile(uri, last_kotlin_lsp_root)
        if not decompiled then
          error(('kotlin_lsp: the server for %s cannot decompile %s'):format(last_kotlin_lsp_root, uri))
        end
        return decompiled.code, decompiled.language
      end

      -- `vim.lsp.enable` attaches only to a buffer with no `buftype`, so `BufWriteCmd` stops writes.
      local kotlin_lsp_jar_group = vim.api.nvim_create_augroup('kotlin-lsp-jar', { clear = true })
      vim.api.nvim_create_autocmd('BufWriteCmd', {
        pattern = 'jar:///*',
        group = kotlin_lsp_jar_group,
        callback = function(event)
          error(('kotlin_lsp: %s is a library file in a jar, it is read-only'):format(event.match))
        end,
      })
      vim.api.nvim_create_autocmd('BufReadCmd', {
        pattern = 'jar:///*',
        group = kotlin_lsp_jar_group,
        callback = function(event)
          local text, filetype = read_kotlin_lsp_jar_entry(event.match)
          vim.bo[event.buf].swapfile = false
          vim.api.nvim_buf_set_lines(event.buf, 0, -1, false, vim.split((text:gsub('\n$', '')), '\n'))
          vim.bo[event.buf].modified = false
          vim.bo[event.buf].modifiable = false
          vim.bo[event.buf].filetype = filetype or ''
        end,
      })

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
        jdtls = {
          -- A library file in a jar belongs to `kotlin_lsp`. It has no file path, so `vim.fs.root`
          -- would give the working directory.
          root_dir = function(bufnr, on_dir)
            if vim.startswith(vim.api.nvim_buf_get_name(bufnr), 'jar:') then
              return
            end
            local root_dir = vim.fs.root(bufnr, vim.lsp.config.jdtls.root_markers)
            if root_dir then
              on_dir(root_dir)
            end
          end,
        },
        kotlin_lsp = {
          cmd = start_kotlin_lsp,
          filetypes = { 'kotlin', 'java' },
          root_dir = find_kotlin_lsp_root,
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

      -- Homebrew installs `kotlin-lsp`, so that all LSP clients run one build.
      local ensure_installed = vim.tbl_filter(function(name)
        return name ~= 'kotlin_lsp'
      end, vim.tbl_keys(servers))
      vim.list_extend(ensure_installed, {
        'stylua',
        'prettier',
        'markdownlint-cli2',
        'detekt', -- Kotlin linter
        'goimports',
        'jsonlint',
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
      }

      vim.lsp.enable(vim.tbl_keys(servers))
    end,
  },
}
