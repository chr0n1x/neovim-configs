local uix_plugins = {
  {
    'rcarriga/nvim-notify',
    priority = 1001,
    lazy = false,
    config = function ()
      vim.notify = require("notify")
      vim.notify.setup({
        top_down = false,
        background_colour = '#434C5E',
      })
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
  {
    'shaunsingh/nord.nvim',
    lazy = false,
    init = function()
      vim.g.nord_contrast = false
      vim.g.nord_borders = false
      vim.g.nord_bold = false
      vim.g.nord_italic = false
      vim.g.nord_disable_background = true
      vim.g.nord_uniform_diff_background = false
      require('nord').set()
    end
  },

  -- NOTE TO SELF: this theme does not have highlights for cmp tab completion
  -- which is REALLY annoying
  -- {
  --   "metalelf0/black-metal-theme-neovim",
  --   lazy = false,
  --   priority = 1000,
  --   config = function()
  --     require("black-metal").setup({
  --       theme = 'mayhem',
  --       colored_dockstrings = false,
  --       variant = 'dark',
  --     })
  --     require("black-metal").load()
  --   end,
  -- },

  {
    "chrisgrieser/nvim-origami",
    event = "VeryLazy",
    opts = {
      foldtext = {
        enabled = true,
        padding = {
          width = 2,
        }
      },
      foldKeymaps = {
        setup = false,
      },
    },
    init = function()
      vim.opt.foldlevel = 99
      vim.opt.foldlevelstart = 99
      vim.api.nvim_set_keymap('n', 'zc', ':lua require("origami").caret()<CR>', {noremap = true, desc = 'Close fold (better if lsp on).'})
      vim.api.nvim_set_keymap('n', 'zo', ':lua require("origami").dollar()<CR>', {noremap = true, desc = 'Open fold.'})
    end,
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
      opts = {
        heading = {
          enabled = false
        }
      }
    }
  )

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
