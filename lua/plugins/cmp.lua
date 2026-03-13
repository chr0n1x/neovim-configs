-- deps that don't destroy a machine with less resources
-- or are absolutely required
local deps = {
    'folke/snacks.nvim', -- lowkey UGH; for downstream notifications

    'hrsh7th/cmp-buffer',
    'hrsh7th/cmp-path',
}

-- default sources that don't kill the machine when trying to load
local sources_list = {
  {name = 'path'},
  {
    name = 'buffer',
    opts = { keyword_length = 4 },
    option = {
      get_bufnrs = function()
        return vim.api.nvim_list_bufs()
      end
    }
  },
}

-- TODO: not sure if there are other simpler ones to add by default
local snippet_configs = {}

-- required for mason

if not IN_PERF_MODE then
  table.insert(deps, 'hrsh7th/cmp-nvim-lsp')
  table.insert(deps, 'hrsh7th/cmp-nvim-lua')
  table.insert(deps, 'L3MON4D3/LuaSnip')
  table.insert(deps, 'andersevenrud/cmp-tmux')
  table.insert(sources_list, {name = 'nvim_lsp' })

  table.insert(sources_list, {
    name = "lazydev",
    group_index = 0, -- set group index to 0 to skip loading LuaLS completions
  })

  table.insert(
    sources_list,
    {
      name = 'tmux',
      keyword_length = 4,
      -- will trigger ALL the things OH MY GOD
      trigger_characters = {},
      option = {
        all_panes = true,
        capture_history = true,
      }
    }
  )

  snippet_configs["expand"] = function(args)
    require('luasnip').lsp_expand(args.body)
  end
end

-- always add these if we can afford the sys resources
-- makes it a bit easier to add in new plugins
if not IN_PERF_MODE then
  table.insert(deps, 'olimorris/codecompanion.nvim')
  table.insert(sources_list, { name = 'codecompanion_models' })
  table.insert(sources_list, { name = 'codecompanion_slash_commands' })
  table.insert(sources_list, { name = 'codecompanion_tools' })
  table.insert(sources_list, { name = 'codecompanion_variables' })
  sources_list["per_filetype"] = { codecompanion = { "codecompanion" } }
end

return {
  'hrsh7th/nvim-cmp',

  lazy = true,
  dependencies = deps,

  config = function()
    local cmp = require('cmp')
    local cmp_select = {behavior = cmp.SelectBehavior.Select}
    local compare = require('cmp.config.compare')
    local compare_cfg = {
      compare.offset,
      compare.exact,
      compare.score,
      compare.recently_used,
      compare.kind,
      compare.sort_text,
      compare.length,
      compare.order,
    }

    cmp.setup({
      sources = sources_list,
      sorting = {
        priority_weight = 2,
        comparators = compare_cfg,
      },
      mapping = cmp.mapping.preset.insert({
        ['<Tab>'] = cmp.mapping.select_next_item(cmp_select),
        ['<CR>'] = cmp.mapping.confirm({ select = true }),
        ['<C-k>'] = cmp.mapping.select_prev_item(cmp_select),
        ['<C-j>'] = cmp.mapping.select_next_item(cmp_select),
        ['<C-y>'] = cmp.mapping.confirm({ select = true }),
        ['<C-Space>'] = cmp.mapping.complete(),
        ["<A-y>"] = require('minuet').make_cmp_map(),
      }),

      window = {
        completion = {
          border = 'rounded',
          winhighlight = 'Normal:CmpNormal',
        }
      },

      snippet = snippet_configs,
    })

    cmp.setup.cmdline(':', {
      -- more or less remove this from cmdline, very annoying
      -- mapping = cmp.mapping.preset.cmdline(),
      sources = cmp.config.sources(
        {
          { name = 'path' }
        },
        {
          { name = 'cmdline' }
        }
      )
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
