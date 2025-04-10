if IN_PERF_MODE then return {} end

return {
  'williamboman/mason.nvim',
  dependencies = {
    'williamboman/mason-lspconfig.nvim',
    'neovim/nvim-lspconfig',
  },
  init = function()
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('user_lsp_attach', {clear = true}),
      callback = function(event)
        vim.keymap.set('n', '<leader>l', function() vim.lsp.buf.hover() end,             { buffer = event.buf, desc = 'LSP commands (default: show symbol def)' })
        vim.keymap.set('n', '<leader>ld', function() vim.lsp.buf.definition() end,       { buffer = event.buf, desc = 'LSP go to definition' })
        vim.keymap.set('n', '<leader>lh', function() vim.lsp.buf.signature_help() end,   { buffer = event.buf, desc = 'LSP signature help' })
        vim.keymap.set('n', '<leader>lw', function() vim.lsp.buf.workspace_symbol() end, { buffer = event.buf, desc = 'LSP search for symbol in workspace' })
        vim.keymap.set('n', '<leader>lD', function() vim.diagnostic.open_float() end,    { buffer = event.buf, desc = 'LSP open diagnostics' })
        vim.keymap.set('n', '<leader>lr', function() vim.lsp.buf.references() end,       { buffer = event.buf, desc = 'LSP buffer/edit symbol actions (default: show refs for current symbol)' })
        vim.keymap.set('n', '<leader>lra', function() vim.lsp.buf.code_action() end,     { buffer = event.buf, desc = 'LSP code action' })
        vim.keymap.set('n', '<leader>lrr', function() vim.lsp.buf.rename() end,          { buffer = event.buf, desc = 'LSP rename' })
      end,
    })

    local lsp_capabilities = require('cmp_nvim_lsp').default_capabilities()

    require('mason').setup({
      -- https://github.com/williamboman/nvim-lsp-installer/discussions/509
      PATH = "prepend",
    })
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
  end
}
