return {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      -- your configuration comes here
      -- or leave it empty to use the default settings
      -- refer to the configuration section below
      bigfile = { enabled = true },
      dashboard = { enabled = true },
      explorer = { enabled = true },
      indent = { enabled = true },
      input = { enabled = true },
      picker = { enabled = true },
      notifier = { enabled = true },
      quickfile = { enabled = true },
      scope = { enabled = true },
      scroll = { enabled = true },
      statuscolumn = { enabled = true },
      words = { enabled = true },
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
    "sphamba/smear-cursor.nvim",
    opts = {},
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
