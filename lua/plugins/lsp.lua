-- taken directly from
-- https://lsp-zero.netlify.app/v3.x/blog/theprimeagens-config-from-2022.html

vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('user_lsp_attach', {clear = true}),
  callback = function(event)
    vim.keymap.set('n', '<leader>l', function() vim.lsp.buf.hover() end,              { buffer = event.buf, desc = 'LSP commands (default: show symbol def)' })
    vim.keymap.set('n', '<leader>ld', function() vim.lsp.buf.definition() end,        { buffer = event.buf, desc = 'LSP go to definition' })
    vim.keymap.set('n', '<leader>lh', function() vim.lsp.buf.signature_help() end,    { buffer = event.buf, desc = 'LSP signature help' })
    vim.keymap.set('n', '<leader>lw', function() vim.lsp.buf.workspace_symbol() end,  { buffer = event.buf, desc = 'LSP search for symbol in workspace' })

    vim.keymap.set('n', '<leader>lD', function() vim.diagnostic.open_float() end,     { buffer = event.buf, desc = 'LSP open diagnostics' })
    vim.keymap.set('n', '[d', function() vim.diagnostic.goto_next() end,              { buffer = event.buf, desc = 'LSP go to next diagnostic' })
    vim.keymap.set('n', ']d', function() vim.diagnostic.goto_prev() end,              { buffer = event.buf, desc = 'LSP go to prev diagnostic' })

    vim.keymap.set('n', '<leader>lb', function() vim.lsp.buf.references() end,        { buffer = event.buf, desc = 'LSP buffer/edit symbol actions (default: show refs for current symbol)' })
    vim.keymap.set('n', '<leader>lba', function() vim.lsp.buf.code_action() end,      { buffer = event.buf, desc = 'LSP code action' })
    vim.keymap.set('n', '<leader>lbr', function() vim.lsp.buf.rename() end,           { buffer = event.buf, desc = 'LSP rename' })
  end,
})

local lsp_capabilities = require('cmp_nvim_lsp').default_capabilities()

require('mason').setup({})
require('mason-lspconfig').setup({
  ensure_installed = {},
  handlers = {
    function(server_name)
      require('lspconfig')[server_name].setup({
        capabilities = lsp_capabilities,
      })
    end,
    lua_ls = function()
      require('lspconfig').lua_ls.setup({
        capabilities = lsp_capabilities,
        settings = {
          Lua = {
            runtime = {
              version = 'LuaJIT'
            },
            diagnostics = {
              globals = {'vim'},
            },
            workspace = {
              library = {
                vim.env.VIMRUNTIME,
              }
            }
          }
        }
      })
    end,
  }
})

local cmp = require('cmp')
local cmp_select = {behavior = cmp.SelectBehavior.Select}

-- this is the function that loads the extra snippets to luasnip
-- from rafamadriz/friendly-snippets
require('luasnip.loaders.from_vscode').lazy_load()

cmp.setup({
  sources = {
    {
      name = 'buffer',
      keyword_length = 2,
      option = {
        get_bufnrs = function()
          return vim.api.nvim_list_bufs()
        end
      }
    },
    {name = 'nvim_lsp', priority = 1000 },
    {
      name = 'tmux',
      option = {
        all_panes = true,
        capture_history = true,
      }
    },
    {name = 'luasnip', keyword_length = 8},
    {name = 'path'},
    {name = 'copilot'},
  },
  mapping = cmp.mapping.preset.insert({
    -- custom mappings
    ['<Tab>'] = cmp.mapping.select_next_item(cmp_select),
    ['<CR>'] = cmp.mapping.confirm({ select = true }),

    ['<C-p>'] = cmp.mapping.select_prev_item(cmp_select),
    ['<C-n>'] = cmp.mapping.select_next_item(cmp_select),
    ['<C-y>'] = cmp.mapping.confirm({ select = true }),
    ['<C-Space>'] = cmp.mapping.complete(),
  }),
  snippet = {
    expand = function(args)
      require('luasnip').lsp_expand(args.body)
    end,
  },
})

-- Change the Diagnostic symbols in the sign column (gutter)
-- (not in youtube nvim video)
local signs = { Error = " ", Warn = " ", Hint = "󰠠 ", Info = " " }
for type, icon in pairs(signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
end
