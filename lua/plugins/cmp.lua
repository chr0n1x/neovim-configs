return {
  'hrsh7th/nvim-cmp',

  dependencies = {
    'hrsh7th/cmp-emoji',
    'hrsh7th/cmp-buffer',
    'hrsh7th/cmp-path',
    'hrsh7th/cmp-nvim-lsp',
    'hrsh7th/cmp-nvim-lua',
    'andersevenrud/cmp-tmux',
  },

  init = function()
    local cmp = require('cmp')
    local cmp_select = {behavior = cmp.SelectBehavior.Select}
    cmp.setup({
      sources = {
        {name = 'nvim_lsp' },
        {name = 'path'},
        {name = 'luasnip', keyword_length = 8},
        {
          name = 'buffer',
          keyword_length = 3,
          option = {
            get_bufnrs = function()
              return vim.api.nvim_list_bufs()
            end
          }
        },
        {
          name = 'tmux',
          option = {
            all_panes = true,
            capture_history = true,
          }
        },
      },

      mapping = cmp.mapping.preset.insert({
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

    -- UI DECORATIONS
    -- Change the Diagnostic symbols in the sign column (gutter)
    -- (not in youtube nvim video)
    local signs = { Error = " ", Warn = " ", Hint = "󰠠 ", Info = " " }
    for type, icon in pairs(signs) do
      local hl = "DiagnosticSign" .. type
      vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
    end
  end
}
