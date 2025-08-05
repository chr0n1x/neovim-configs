local deps = {
  { 'milanglacier/minuet-ai.nvim', lazy = false },
  'nvim-web-devicons'
}

local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

LUALINE_SECTIONS = {
  lualine_a = {'mode'},
  lualine_b = {'branch'},

  lualine_x = {'filename'},
  lualine_y = {
    'encoding',
    'fileformat',
    'filetype',
    {
      'lsp_status',
      icon = '', -- f013
      symbols = {
        -- Standard unicode symbols to cycle through for LSP progress:
        spinner = spinner,
        -- Standard unicode symbol for when LSP is done:
        done = '✓',
        -- Delimiter inserted between LSP names:
        separator = ' ',
      },
      -- List of LSP names to ignore (e.g., `null-ls`):
      ignore_lsp = {},
    }
  },
  lualine_z = {'location'}
}

return {
  'hoob3rt/lualine.nvim',
  lazy = false,
  priority = 1000,
  dependencies = deps,
  opts = function(_, opts)
    if opts == nil then
      opts = {}
    end

    opts.sections = LUALINE_SECTIONS

    opts.options = {
      icons_enabled = true,
      theme = 'iceberg_dark',
      component_separators = {'|', '|'},
    }

    table.insert(
      opts.sections.lualine_x,
      {
        require 'minuet.lualine',
        -- the follwing is the default configuration
        -- the name displayed in the lualine. Set to "provider", "model" or "both"
        -- display_name = 'both',
        -- separator between provider and model name for option "both"
        -- provider_model_separator = ':',
        -- whether show display_name when no completion requests are active
        -- display_on_idle = false,
      }
    )
  end
}
