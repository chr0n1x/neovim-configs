
local uix_plugins = {
  {
    'rcarriga/nvim-notify',
    priority = 1001,
    lazy = false,
    config = function ()
      vim.notify = require("notify")
    end,
    keys = {
      { '<leader>e', ':lua require("notify").dismiss()<CR>', desc = "Clear notifications." },
      { '<leader>ec', ':lua require("notify").dismiss()<CR>', desc = "Clear notifications." },
      { '<leader>eh', ':Telescope notify<CR>', desc = "View notifications in Telescope." },
    }
  },

  -- I hate the notification plugins in this thing w/ a passion
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      dashboard = {
        enabled = DISABLED_IF_IN_PERF_MODE,
        preset = {
          header = [[
░░░░░░░█▐▓▓░████▄▄▄█▀▄▓▓▓▌█
░░░░░▄█▌▀▄▓▓▄▄▄▄▀▀▀▄▓▓▓▓▓▌█
░░░▄█▀▀▄▓█▓▓▓▓▓▓▓▓▓▓▓▓▀░▓▌█
░░█▀▄▓▓▓███▓▓▓███▓▓▓▄░░▄▓▐█▌
░█▌▓▓▓▀▀▓▓▓▓███▓▓▓▓▓▓▓▄▀▓▓▐█
▐█▐██▐░▄▓▓▓▓▓▀▄░▀▓▓▓▓▓▓▓▓▓▌█▌
█▌███▓▓▓▓▓▓▓▓▐░░▄▓▓███▓▓▓▄▀▐█
█▐█▓▀░░▀▓▓▓▓▓▓▓▓▓██████▓▓▓▓▐█
▌▓▄▌▀░▀░▐▀█▄▓▓██████████▓▓▓▌█▌
▌▓▓▓▄▄▀▀▓▓▓▀▓▓▓▓▓▓▓▓█▓█▓█▓▓▌█▌
█▐▓▓▓▓▓▓▄▄▄▓▓▓▓▓▓█▓█▓█▓█▓▓▓▐█
Forever MoonJanglin'
]],

        }
      },
      indent = { enabled = DISABLED_IF_IN_PERF_MODE },
      scope = { enabled = true },
      statuscolumn = { enabled = DISABLED_IF_IN_PERF_MODE },
      layout = { enabled = true },
      win = { enabled = DISABLED_IF_IN_PERF_MODE },
    }
  },

  {
    'tris203/precognition.nvim',
    opts = {
      startVisible = true,
      showBlankVirtLine = false,
      highlightColor = { link = "LineNr" },
      gutterHints = {
        G = { text = "G", prio = 10 },
        gg = { text = "gg", prio = 9 },
        PrevParagraph = { text = "{", prio = 8 },
        NextParagraph = { text = "}", prio = 8 },
      },
    },
    keys = {
      {'<leader>P', ':lua require("precognition").peek()<CR>', desc = 'toggle precognition'},
    }
  },

  -- Im too weenie hut juniors for this
  -- {
  --   "m4xshen/hardtime.nvim",
  --   dependencies = { "MunifTanjim/nui.nvim" },
  --   opts = {}
  -- },

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
