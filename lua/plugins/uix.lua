local uix_plugins = {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      dashboard = { enabled = DISABLED_IF_IN_PERF_MODE },
      indent = { enabled = DISABLED_IF_IN_PERF_MODE },
      notify = { enabled = DISABLED_IF_IN_PERF_MODE },
      notifier = {
        enabled = DISABLED_IF_IN_PERF_MODE,
        history = true,
        level = vim.log.levels.TRACE,
        timeout = 8000,
      },
      scope = { enabled = true },
      statuscolumn = { enabled = DISABLED_IF_IN_PERF_MODE },
      layout = { enabled = true },
      win = { enabled = DISABLED_IF_IN_PERF_MODE },
    }
  },

  {
    'hoob3rt/lualine.nvim',
    lazy = false,
    dependencies = {
      'nvim-web-devicons'
    },
    opts = {
      options = {
        icons_enabled = true,
        theme = 'iceberg_dark',
        component_separators = {'|', '|'},
      },
      sections = {
        lualine_a = {'mode'},
        lualine_b = {'branch'},
        lualine_c = {'filename'},
        lualine_x = {'encoding', 'fileformat', 'filetype'},
        lualine_y = {'progress'},
        lualine_z = {'location'}
      },
      inactive_sections = {
        lualine_c = {'filename'},
        lualine_x = {'location'},
      }
    }
  },


  {
    'shaunsingh/nord.nvim',
    lazy = false,
    init = function()
      require('nord').set()
    end
  },

  {
    "anuvyklack/windows.nvim",
    lazy = false,
    dependencies = {
      "anuvyklack/middleclass",
      "anuvyklack/animation.nvim"
    },
    init = function()
      vim.o.winwidth = 10
      vim.o.winminwidth = 10
      vim.o.equalalways = false
      require('windows').setup()
    end
  }
}

if not IN_PERF_MODE then
  table.insert(
    uix_plugins,
    -- initially did not like this, but very useful for REALLY big screens
    { "sphamba/smear-cursor.nvim", opts = {} }
  )

  table.insert(
    uix_plugins,
    {
      'MeanderingProgrammer/render-markdown.nvim',
      dependencies = { 'nvim-treesitter/nvim-treesitter' },
      opts = {}
    }
  )
end

return uix_plugins
