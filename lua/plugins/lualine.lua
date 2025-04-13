local deps = {
  'nvim-web-devicons'
}

local spinner = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

local sections = {
  lualine_a = {'mode'},
  lualine_b = {'branch'},
  lualine_c = { function() return "⚠️ AI missing" end },

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

if IN_PERF_MODE then
  sections.lualine_c = {
    function () return " AI cmp disabled (perf. mode)" end
  }
end

if USING_OLLAMA and OLLAMA_MODEL_PRESENT then
  sections.lualine_c = {
    function ()
      -- TODO: IWANNA MAKE THIS FAST AF BOI
      return  "🦙 " .. spinner[os.date('%S') % #spinner + 1]
    end
  }
end

return {
    'hoob3rt/lualine.nvim',
    lazy = false,
    dependencies = deps,
    opts = {
      options = {
        icons_enabled = true,
        theme = 'iceberg_dark',
        component_separators = {'|', '|'},
      },
      sections = sections,
      inactive_sections = {
        lualine_c = {'filename'},
        lualine_x = {'location'},
      }
    }
  }
