local uix_plugins = {
  {
    'rcarriga/nvim-notify',
    priority = 1001,
    lazy = false,
    config = function ()
      vim.notify = require("notify")
    end,
    keys = {
      { '<leader>eh', ':lua require("notify").dismiss()<CR>', desc = "Clear notifications." },
      { '<leader>e', ':Telescope notify<CR>', desc = "View notifications in Telescope." },
    }
  },

  -- I hate the notification plugins in this thing w/ a passion
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      dashboard = {
        enabled = true,
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

  -- adds borders to cmp popups because OH MY GOD
  {
    'mikesmithgh/borderline.nvim',
    enabled = true,
    lazy = true,
    event = 'VeryLazy',
    config = function() require('borderline').setup({}) end,
  },

  {
    'tris203/precognition.nvim',
    opts = {
      startVisible = false,
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
      {'<leader>P', ':lua require("precognition").toggle()<CR>', desc = 'toggle precognition'},
    }
  },

  {
    "m4xshen/hardtime.nvim",
    dependencies = { "MunifTanjim/nui.nvim" },
    config = function ()
      -- Im too weenie hut juniors for this
      require("hardtime").setup({
        restriction_mode = "hint",
        callback = function(text)
          vim.notify(text, vim.log.levels.WARN, { render = "compact" })
        end
      })
    end,
  },

  -- color schemes; I'm conflicted
  -- {
  --   'shaunsingh/nord.nvim',
  --   lazy = false,
  --   init = function() require('nord').set() end
  -- },
  {
    "metalelf0/black-metal-theme-neovim",
    lazy = false,
    priority = 1000,
    config = function()
      require("black-metal").setup({
        theme = 'taake',
        variant = 'dark',
        alt_bg = false,
        colored_docstrings = false,
      })
      require("black-metal").load()
    end,
  }
}

if not IN_PERF_MODE then
  table.insert(
    uix_plugins,
    -- initially did not like this, but very useful for REALLY big screens
    { "sphamba/smear-cursor.nvim", opts = {} }
  )

  -- table.insert(
  --   uix_plugins,
  --   {
  --     'MeanderingProgrammer/render-markdown.nvim',
  --     dependencies = { 'nvim-treesitter/nvim-treesitter' },
  --     opts = {}
  --   }
  -- )

  table.insert(
    uix_plugins,
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
  )
end

return uix_plugins
