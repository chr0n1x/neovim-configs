local uix_plugins = {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      bigfile = { enabled = true },
      dashboard = { enabled = DISABLED_FOR_PERF },
      -- consistently clashes and screws w/ the UI when using cmp
      -- TODO: optionally enable/disable w/ cmp in "lite" envs
      explorer = { enabled = false },
      indent = { enabled = DISABLED_FOR_PERF },
      input = { enabled = true },
      picker = { enabled = false },
      notifier = { enabled = DISABLED_FOR_PERF },
      quickfile = { enabled = true },
      scope = { enabled = true },
      scroll = { enabled = false },
      statuscolumn = { enabled = DISABLED_FOR_PERF },
      words = { enabled = true },
      popupmenu = { enabled = false },
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
  },
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
